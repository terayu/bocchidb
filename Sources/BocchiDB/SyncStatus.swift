/// Live Sync の状態。
public enum SyncStatus: Sendable, Equatable {
    /// 開始直後。チェックポイントの読み込みと、最初の追いつきの途中。
    case connecting
    /// 文書を送受信している。
    case active
    /// 追いついていて、変更を待っている。
    case idle
    /// 一時的なエラー（通信できないなど）で、再試行を待っている。
    case offline
    /// `live()` が終わった（キャンセルまたはエラー）。
    case stopped
}

/// pull と push の状態をまとめ、変わったときだけ知らせる。
actor StatusTracker {
    enum Side { case pull, push }

    private let handler: @Sendable (SyncStatus) -> Void
    private var pull: SyncStatus = .connecting
    private var push: SyncStatus = .connecting
    private var reported: SyncStatus?

    init(handler: @escaping @Sendable (SyncStatus) -> Void) {
        self.handler = handler
    }

    func start() { report(combined) }

    func set(_ side: Side, _ status: SyncStatus) {
        switch side {
        case .pull: pull = status
        case .push: push = status
        }
        report(combined)
    }

    func stop() { report(.stopped) }

    /// 優先順位：offline > connecting > active > idle。
    private var combined: SyncStatus {
        let sides = [pull, push]
        for status in [SyncStatus.offline, .connecting, .active] where sides.contains(status) {
            return status
        }
        return .idle
    }

    private func report(_ status: SyncStatus) {
        guard status != reported, reported != .stopped else { return }
        reported = status
        handler(status)
    }
}
