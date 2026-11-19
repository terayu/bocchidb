import Foundation

/// 一時的なエラー（通信エラー、HTTP 5xx / 429）に対する再試行の設定。
public struct RetryPolicy: Sendable, Equatable {
    /// 最初の 1 回を含む最大試行回数。1 なら再試行しない。
    public var maxAttempts: Int
    /// 1 回目の再試行までの待ち時間（秒）。以降は 2 倍ずつ増える。
    public var initialDelay: TimeInterval
    /// 待ち時間の上限（秒）。
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, initialDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 30) {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy()

    /// `attempt` 回目（1 始まり）が失敗した後の待ち時間。
    /// 多数の端末が同時に再接続しないよう、50〜100% の範囲でゆらぎを入れる。
    func delay(afterAttempt attempt: Int) -> TimeInterval {
        let exponential = initialDelay * pow(2, Double(attempt - 1))
        return min(exponential, maxDelay) * Double.random(in: 0.5...1)
    }

    static func isRetryable(status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            true
        default:
            false
        }
    }
}
