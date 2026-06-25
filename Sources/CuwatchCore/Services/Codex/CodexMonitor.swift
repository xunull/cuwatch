import Foundation

/// Drives `CodexReader` on a poll loop.
public final class CodexReaderAdapter: PollOutcomeProducing {
    public typealias Outcome = CodexReader.Result

    public let reader: CodexReader

    public init(reader: CodexReader) {
        self.reader = reader
    }

    public func pollOnce(now: Date) async throws -> CodexReader.Result {
        // `priority: .utility` puts the read on a QoS-utility pool, not the
        // user-initiated cooperative pool the rest of the monitor pipeline
        // shares. Cache-miss reads can hit ~50MB JSONL files; keeping that
        // off the cooperative pool ensures Claude/Minimax monitors aren't
        // starved if Codex hits a slow disk. See plan #3b.
        await Task.detached(priority: .utility) { [reader] in
            reader.read(now: now)
        }.value
    }

    public func makeSnapshot(from outcome: CodexReader.Result, now: Date) -> UsageSnapshot? {
        outcome.snapshot
    }

    public func unconfiguredReason(from outcome: CodexReader.Result) -> UnconfiguredReason? {
        switch outcome.probe {
        case .binaryNotInstalled: return .codexNotInstalled
        case .notAuthenticated:   return .codexNotAuthenticated
        case .authenticated:      return nil
        }
    }

    public func failureReason(from error: Error) -> MonitorFailureReason {
        .fileSystemError(message: "\(error)")
    }
}

public extension BaseServiceMonitor where Reader == CodexReaderAdapter {
    static func codex(
        store: StateStore,
        reader: CodexReader,
        interval: TimeInterval = Tokens.Polling.defaultIntervalSeconds,
        scheduler: SchedulerProvider = DispatchQueueMainScheduler()
    ) -> BaseServiceMonitor<CodexReaderAdapter> {
        BaseServiceMonitor<CodexReaderAdapter>(
            serviceID: .codex,
            store: store,
            reader: CodexReaderAdapter(reader: reader),
            interval: interval,
            scheduler: scheduler
        )
    }
}
