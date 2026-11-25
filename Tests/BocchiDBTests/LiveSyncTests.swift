import Foundation
import Testing
@testable import BocchiDB

@Suite(.timeLimit(.minutes(1))) struct LiveSyncTests {
    /// 接続できない間（オフライン）もエラーで終わらずに再試行を続け、キャンセルするとすぐ終わる。
    @Test func keepsRunningWhileOfflineAndStopsOnCancel() async throws {
        let db = try BocchiDB(path: ":memory:")
        // ポート 9（discard）は通常どこも待ち受けていないので、接続は拒否される。
        let replicator = Replicator(
            local: db, remote: URL(string: "http://127.0.0.1:9/inspections")!,
            retryPolicy: RetryPolicy(maxAttempts: 1, initialDelay: 0.05, maxDelay: 0.1))

        let finished = Flag()
        let statuses = StatusRecorder()
        let live = Task {
            defer { Task { await finished.set() } }
            try await replicator.live(onStatus: statuses.record)
        }

        // 負荷が高いとオフラインになるまで時間がかかるので、決まった時間ではなく状態を待つ。
        while !statuses.values.contains(.offline) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await finished.value == false)

        live.cancel()
        try await live.value  // キャンセルではエラーを投げない
        #expect(statuses.values == [.connecting, .offline, .stopped])
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}
