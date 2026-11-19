import Foundation
import Testing
@testable import BocchiDB

/// モックの HTTP で、再試行と Cookie 認証の動きを検証する。
@Suite(.serialized) struct CouchClientTests {
    private let databaseURL = URL(string: "http://couch.test/inspections")!
    private let noDelay = RetryPolicy(maxAttempts: 3, initialDelay: 0, maxDelay: 0)
    private let emptyChanges = #"{"results":[],"last_seq":"0"}"#

    private func client(auth: Authentication = .none, retry: RetryPolicy? = nil) -> CouchClient {
        CouchClient(databaseURL: databaseURL, auth: auth, session: MockServer.session, retryPolicy: retry ?? noDelay)
    }

    // MARK: - 再試行

    @Test func retriesServerErrorThenSucceeds() async throws {
        let paths = try await MockServer.run(responses: [.status(503), .json(200, emptyChanges)]) {
            _ = try await client().changes(since: .int(0), limit: 10)
        }
        #expect(paths == ["/inspections/_changes", "/inspections/_changes"])
    }

    @Test func retriesTooManyRequests() async throws {
        let paths = try await MockServer.run(responses: [.status(429), .json(200, emptyChanges)]) {
            _ = try await client().changes(since: .int(0), limit: 10)
        }
        #expect(paths.count == 2)
    }

    @Test func retriesNetworkError() async throws {
        let paths = try await MockServer.run(responses: [.error(.networkConnectionLost), .json(200, emptyChanges)]) {
            _ = try await client().changes(since: .int(0), limit: 10)
        }
        #expect(paths.count == 2)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let paths = try await MockServer.run(responses: [.status(500), .status(500), .status(500), .status(500)]) {
            await #expect(throws: ReplicationError.http(status: 500, body: "")) {
                try await client().changes(since: .int(0), limit: 10)
            }
        }
        #expect(paths.count == 3)
    }

    @Test func doesNotRetryClientError() async throws {
        let paths = try await MockServer.run(responses: [.status(400), .json(200, emptyChanges)]) {
            await #expect(throws: ReplicationError.http(status: 400, body: "")) {
                try await client().changes(since: .int(0), limit: 10)
            }
        }
        #expect(paths.count == 1)
    }

    @Test func doesNotRetryNonTransientNetworkError() async throws {
        let paths = try await MockServer.run(responses: [.error(.badURL), .json(200, emptyChanges)]) {
            await #expect(throws: URLError.self) {
                try await client().changes(since: .int(0), limit: 10)
            }
        }
        #expect(paths.count == 1)
    }

    /// 途中で切れた応答（CouchDB の停止時に起こる）は malformedResponse として区別する。
    @Test func reportsTruncatedResponseAsMalformed() async throws {
        _ = try await MockServer.run(responses: [.json(200, #"{"results":[{"id":"a","#)]) {
            await #expect {
                try await client().changes(since: .int(0), limit: 10)
            } throws: { error in
                if case ReplicationError.malformedResponse = error { true } else { false }
            }
        }
    }

    /// JSON として正しいが形が違う応答は、待っても直らないので invalidResponse のまま。
    @Test func reportsUnexpectedShapeAsInvalid() async throws {
        _ = try await MockServer.run(responses: [.json(200, #"{"rows":[]}"#)]) {
            await #expect {
                try await client().changes(since: .int(0), limit: 10)
            } throws: { error in
                if case ReplicationError.invalidResponse = error { true } else { false }
            }
        }
    }

    @Test func delayGrowsExponentiallyUpToMax() {
        let policy = RetryPolicy(maxAttempts: 10, initialDelay: 1, maxDelay: 5)
        #expect((0.5...1).contains(policy.delay(afterAttempt: 1)))
        #expect((1...2).contains(policy.delay(afterAttempt: 2)))
        #expect((2...4).contains(policy.delay(afterAttempt: 3)))
        #expect((2.5...5).contains(policy.delay(afterAttempt: 8)))
    }

    // MARK: - Cookie 認証

    @Test func logsInAndSendsCookie() async throws {
        let session = Authentication.session(username: "u", password: "p")
        let c = client(auth: session)
        let requests = try await MockServer.runRecordingRequests(responses: [
            .json(200, #"{"ok":true}"#, cookie: "AuthSession=first"),
            .json(200, emptyChanges),
            .json(200, emptyChanges),
        ]) {
            _ = try await c.changes(since: .int(0), limit: 10)
            _ = try await c.changes(since: .int(0), limit: 10)
        }
        #expect(requests.map(\.path) == ["/_session", "/inspections/_changes", "/inspections/_changes"])
        #expect(requests[0].method == "POST")
        #expect(requests[1].cookie == "AuthSession=first")
        #expect(requests[2].cookie == "AuthSession=first")
    }

    @Test func usesRefreshedCookieFromResponse() async throws {
        let c = client(auth: .session(username: "u", password: "p"))
        let requests = try await MockServer.runRecordingRequests(responses: [
            .json(200, #"{"ok":true}"#, cookie: "AuthSession=first"),
            .json(200, emptyChanges, cookie: "AuthSession=refreshed"),
            .json(200, emptyChanges),
        ]) {
            _ = try await c.changes(since: .int(0), limit: 10)
            _ = try await c.changes(since: .int(0), limit: 10)
        }
        #expect(requests[2].cookie == "AuthSession=refreshed")
    }

    @Test func logsInAgainOnUnauthorized() async throws {
        let c = client(auth: .session(username: "u", password: "p"))
        let requests = try await MockServer.runRecordingRequests(responses: [
            .json(200, #"{"ok":true}"#, cookie: "AuthSession=expired"),
            .status(401),
            .json(200, #"{"ok":true}"#, cookie: "AuthSession=new"),
            .json(200, emptyChanges),
        ]) {
            _ = try await c.changes(since: .int(0), limit: 10)
        }
        #expect(requests.map(\.path) == ["/_session", "/inspections/_changes", "/_session", "/inspections/_changes"])
        #expect(requests[3].cookie == "AuthSession=new")
    }

    @Test func failsWhenLoginIsRejected() async throws {
        let paths = try await MockServer.run(responses: [.status(401), .status(401)]) {
            await #expect(throws: ReplicationError.http(status: 401, body: "")) {
                try await client(auth: .session(username: "u", password: "wrong")).changes(since: .int(0), limit: 10)
            }
        }
        #expect(paths == ["/_session"])
    }

    @Test func doesNotLoopOnRepeatedUnauthorized() async throws {
        let paths = try await MockServer.run(responses: [
            .json(200, #"{"ok":true}"#, cookie: "AuthSession=a"),
            .status(401),
            .json(200, #"{"ok":true}"#, cookie: "AuthSession=b"),
            .status(401),
        ]) {
            await #expect(throws: ReplicationError.http(status: 401, body: "")) {
                try await client(auth: .session(username: "u", password: "p")).changes(since: .int(0), limit: 10)
            }
        }
        #expect(paths.count == 4)
    }
}

// MARK: - モック HTTP

/// 用意した応答を順番に返すモックサーバー。テストは直列に実行すること。
final class MockServer: URLProtocol, @unchecked Sendable {
    enum Response {
        case status(Int)
        case json(Int, String, cookie: String? = nil)
        case error(URLError.Code)
    }

    struct RecordedRequest {
        let path: String
        let method: String
        let cookie: String?
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockServer.self]
        return URLSession(configuration: configuration)
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    /// `responses` を用意して `body` を実行し、受けたリクエストのパスを返す。
    static func run(responses: [Response], _ body: () async throws -> Void) async throws -> [String] {
        try await runRecordingRequests(responses: responses, body).map(\.path)
    }

    static func runRecordingRequests(responses: [Response], _ body: () async throws -> Void) async throws -> [RecordedRequest] {
        lock.withLock { queue = responses; recorded = [] }
        try await body()
        return lock.withLock { recorded }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response: Response? = Self.lock.withLock {
            Self.recorded.append(RecordedRequest(
                path: request.url?.path ?? "", method: request.httpMethod ?? "",
                cookie: request.value(forHTTPHeaderField: "Cookie")))
            return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        }
        let url = request.url!

        switch response {
        case .status(let status):
            finish(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        case .json(let status, let body, let cookie):
            var headers = ["Content-Type": "application/json"]
            if let cookie { headers["Set-Cookie"] = "\(cookie); Version=1; Path=/; HttpOnly" }
            finish(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }

    private func finish(_ response: HTTPURLResponse, _ data: Data) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
