import Foundation
import Testing
@testable import BocchiDB

/// コールバックで受け取った状態を記録する。
final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SyncStatus] = []

    var values: [SyncStatus] { lock.withLock { recorded } }
    func record(_ status: SyncStatus) { lock.withLock { recorded.append(status) } }
}

@Suite struct StatusTrackerTests {
    @Test func combinesPullAndPushStatus() async {
        let recorder = StatusRecorder()
        let tracker = StatusTracker(handler: recorder.record)

        await tracker.start()
        await tracker.set(.pull, .idle)        // push がまだ connecting
        await tracker.set(.push, .idle)
        await tracker.set(.pull, .active)
        await tracker.set(.push, .offline)     // offline が最優先
        await tracker.set(.push, .idle)
        await tracker.set(.pull, .idle)
        #expect(recorder.values == [.connecting, .idle, .active, .offline, .active, .idle])
    }

    @Test func reportsOnlyChanges() async {
        let recorder = StatusRecorder()
        let tracker = StatusTracker(handler: recorder.record)
        await tracker.start()
        await tracker.set(.pull, .offline)
        await tracker.set(.push, .offline)
        await tracker.set(.pull, .offline)
        #expect(recorder.values == [.connecting, .offline])
    }

    @Test func reportsNothingAfterStopped() async {
        let recorder = StatusRecorder()
        let tracker = StatusTracker(handler: recorder.record)
        await tracker.start()
        await tracker.stop()
        await tracker.set(.pull, .idle)
        await tracker.set(.push, .idle)
        await tracker.stop()
        #expect(recorder.values == [.connecting, .stopped])
    }
}
