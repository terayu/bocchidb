import Foundation

/// CouchDB の認証方式。
public enum Authentication: Sendable, Equatable {
    case none
    case basic(username: String, password: String)
    /// `POST /_session` でログインし、Cookie（AuthSession）で認証する。
    case session(username: String, password: String)
}

/// Cookie 認証の状態。Replicator ごとに持ち、グローバルな Cookie ストレージは使わない。
actor CookieSession {
    private let loginURL: URL
    private let username: String
    private let password: String
    private var cookie: String?

    init(serverURL: URL, username: String, password: String) {
        self.loginURL = serverURL.appending(path: "_session")
        self.username = username
        self.password = password
    }

    /// 現在の Cookie を返す。まだなければログインする。
    func currentCookie(using session: URLSession) async throws -> String {
        if let cookie { return cookie }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["name": username, "password": password])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReplicationError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReplicationError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let cookie = Self.authCookie(in: http) else {
            throw ReplicationError.invalidResponse("_session did not return AuthSession cookie")
        }
        self.cookie = cookie
        return cookie
    }

    /// CouchDB は有効期限が近づくと新しい Cookie を返すので、あれば差し替える。
    func update(from response: HTTPURLResponse) {
        if let cookie = Self.authCookie(in: response) { self.cookie = cookie }
    }

    func invalidate() { cookie = nil }

    private static func authCookie(in response: HTTPURLResponse) -> String? {
        guard let url = response.url,
              let headers = response.allHeaderFields as? [String: String],
              let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                  .first(where: { $0.name == "AuthSession" && !$0.value.isEmpty })
        else { return nil }
        return "\(cookie.name)=\(cookie.value)"
    }
}

/// レプリケーション中のエラー。
public enum ReplicationError: Error, Equatable, Sendable {
    /// CouchDB が 2xx 以外を返した。
    case http(status: Int, body: String)
    /// CouchDB の応答を解釈できなかった（JSON としては正しいが、想定した形ではない）。
    case invalidResponse(String)
    /// 応答が JSON として壊れていた。接続が途中で切れた場合（CouchDB の停止中など）に起こるため、一時的なエラーとして扱う。
    case malformedResponse(String)
    /// 文書の取得に失敗した（`_bulk_get` の error）。
    case documentReadFailed(id: String, reason: String)
    /// 文書の書き込みに失敗した（`_bulk_docs` の error）。
    case documentWriteFailed(id: String, reason: String)
}

/// CouchDB の 1 データベースに対する HTTP クライアント（レプリケーションに必要な API のみ）。
struct CouchClient: Sendable {
    let databaseURL: URL
    let auth: Authentication
    let session: URLSession
    let retryPolicy: RetryPolicy
    private let cookieSession: CookieSession?

    init(databaseURL: URL, auth: Authentication, session: URLSession, retryPolicy: RetryPolicy = .default) {
        self.databaseURL = databaseURL
        self.auth = auth
        self.session = session
        self.retryPolicy = retryPolicy
        self.cookieSession = if case .session(let username, let password) = auth {
            CookieSession(serverURL: databaseURL.deletingLastPathComponent(), username: username, password: password)
        } else { nil }
    }

    struct ChangesResponse: Decodable {
        struct Row: Decodable {
            struct Rev: Decodable { let rev: String }
            let id: String
            let changes: [Rev]
        }
        let results: [Row]
        let lastSeq: JSONValue

        enum CodingKeys: String, CodingKey {
            case results
            case lastSeq = "last_seq"
        }
    }

    /// `GET /{db}/_changes?style=all_docs`
    ///
    /// `longpoll` が true なら、変更がないときは CouchDB 側で最大 `longpollTimeout` ミリ秒待ってから空の結果を返す。
    func changes(since: JSONValue, limit: Int, longpoll: Bool = false) async throws -> ChangesResponse {
        var query = [
            URLQueryItem(name: "style", value: "all_docs"),
            URLQueryItem(name: "since", value: Self.queryValue(since)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if longpoll {
            query += [
                URLQueryItem(name: "feed", value: "longpoll"),
                URLQueryItem(name: "timeout", value: String(Self.longpollTimeout)),
            ]
        }
        let data = try await send("GET", "_changes", query: query)
        return try decode(ChangesResponse.self, from: data)
    }

    struct RevsDiffEntry: Decodable {
        let missing: [String]
        /// リモートにある、`missing` の祖先かもしれないリーフ。添付を stub で送れるかの判断に使う。
        let possibleAncestors: [String]?

        enum CodingKeys: String, CodingKey {
            case missing
            case possibleAncestors = "possible_ancestors"
        }
    }

    /// `POST /{db}/_revs_diff`：リモートに存在しない rev を返す。
    func revsDiff(_ revsByID: [String: [String]]) async throws -> [String: RevsDiffEntry] {
        let body = JSONValue.object(revsByID.mapValues { .array($0.map(JSONValue.string)) })
        let data = try await send("POST", "_revs_diff", body: body)
        return try decode([String: RevsDiffEntry].self, from: data)
    }

    struct BulkGetItem {
        let id: String
        let rev: String
        /// ローカルにある rev。これ以降に変わっていない添付は、データなしの stub で返ってくる。
        let attsSince: [String]
    }

    /// `POST /{db}/_bulk_get?revs=true&attachments=true`：指定した rev を履歴（`_revisions`）と添付付きで取得する。
    func bulkGet(_ items: [BulkGetItem]) async throws -> [[String: JSONValue]] {
        struct Response: Decodable {
            struct Result: Decodable { let id: String; let docs: [Entry] }
            struct Entry: Decodable { let ok: [String: JSONValue]?; let error: [String: JSONValue]? }
            let results: [Result]
        }
        let body: JSONValue = ["docs": .array(items.map { item in
            var doc: [String: JSONValue] = ["id": .string(item.id), "rev": .string(item.rev)]
            if !item.attsSince.isEmpty { doc["atts_since"] = .array(item.attsSince.map(JSONValue.string)) }
            return .object(doc)
        })]
        let data = try await send("POST", "_bulk_get", query: [
            URLQueryItem(name: "revs", value: "true"),
            URLQueryItem(name: "attachments", value: "true"),
        ], body: body)

        var docs: [[String: JSONValue]] = []
        for result in try decode(Response.self, from: data).results {
            for entry in result.docs {
                if let doc = entry.ok {
                    docs.append(doc)
                } else {
                    throw ReplicationError.documentReadFailed(id: result.id, reason: Self.reason(entry.error))
                }
            }
        }
        return docs
    }

    /// `POST /{db}/_bulk_docs`（`new_edits: false`）：rev と履歴を保ったまま書き込む。
    func bulkDocs(_ docs: [JSONValue]) async throws {
        let body: JSONValue = ["docs": .array(docs), "new_edits": false]
        let data = try await send("POST", "_bulk_docs", body: body)
        // new_edits=false では、失敗した文書だけが応答に含まれる。
        for entry in try decode([[String: JSONValue]].self, from: data) where entry["error"] != nil {
            let id = if case .string(let id) = entry["id"] { id } else { "" }
            throw ReplicationError.documentWriteFailed(id: id, reason: Self.reason(entry))
        }
    }

    /// `GET /{db}/_local/{id}`。存在しなければ `nil`。
    func getLocal(_ id: String) async throws -> [String: JSONValue]? {
        do {
            return try decode([String: JSONValue].self, from: try await send("GET", "_local/\(id)"))
        } catch ReplicationError.http(status: 404, _) {
            return nil
        }
    }

    /// `PUT /{db}/_local/{id}`。新しい rev を返す。
    func putLocal(_ id: String, body: [String: JSONValue]) async throws -> String {
        struct Response: Decodable { let rev: String }
        return try decode(Response.self, from: try await send("PUT", "_local/\(id)", body: .object(body))).rev
    }

    /// URLSession の既定のタイムアウト（60 秒）より短くしておく。
    static let longpollTimeout = 25_000

    // MARK: - Private

    private func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil
    ) async throws -> Data {
        var components = URLComponents(url: databaseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .basic(let username, let password) = auth {
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        var attempt = 1
        var reauthenticated = false
        while true {
            do {
                if let cookieSession {
                    request.setValue(try await cookieSession.currentCookie(using: session), forHTTPHeaderField: "Cookie")
                }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ReplicationError.invalidResponse("not an HTTP response")
                }
                await cookieSession?.update(from: http)

                // Cookie の期限切れ：一度だけログインし直す（試行回数には数えない）。
                if http.statusCode == 401, let cookieSession, !reauthenticated {
                    reauthenticated = true
                    await cookieSession.invalidate()
                    continue
                }
                if RetryPolicy.isRetryable(status: http.statusCode), attempt < retryPolicy.maxAttempts {
                    try await waitBeforeRetry(after: &attempt)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ReplicationError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
                }
                return data
            } catch let error as URLError where RetryPolicy.isRetryable(error) && attempt < retryPolicy.maxAttempts {
                try await waitBeforeRetry(after: &attempt)
            } catch ReplicationError.http(let status, _)
                where RetryPolicy.isRetryable(status: status) && attempt < retryPolicy.maxAttempts {
                // ログイン（_session）が 5xx / 429 を返した場合。
                try await waitBeforeRetry(after: &attempt)
            }
        }
    }

    private func waitBeforeRetry(after attempt: inout Int) async throws {
        let delay = retryPolicy.delay(afterAttempt: attempt)
        attempt += 1
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            // 先頭からして JSON として読めない＝途中で切れた応答など。
            throw ReplicationError.malformedResponse("\(T.self): \(context.debugDescription)")
        } catch {
            throw ReplicationError.invalidResponse("\(T.self): \(error)")
        }
    }

    /// seq は不透明な値なので、文字列ならそのまま、数値なら数字としてクエリに載せる。
    private static func queryValue(_ seq: JSONValue) -> String {
        switch seq {
        case .string(let s): s
        case .int(let i): String(i)
        default: "0"
        }
    }

    private static func reason(_ error: [String: JSONValue]?) -> String {
        guard let error else { return "unknown" }
        return ["error", "reason"].compactMap { key in
            if case .string(let s) = error[key] { s } else { nil }
        }.joined(separator: ": ")
    }
}
