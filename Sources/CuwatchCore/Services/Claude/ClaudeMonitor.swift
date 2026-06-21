import Foundation

/// Drives `ClaudeReader` on a poll loop, publishing into `StateStore`.
///
/// FDA detection: `ClaudeReader.read` doesn't currently distinguish between
/// "no usage in the last 5h" and "I can't read the directory at all". For v1
/// we surface "no recent activity" as the active-with-no-snapshot state; a
/// real FDA TCC probe is a Phase 2 task #9 follow-up.
public final class ClaudeReaderAdapter: PollOutcomeProducing {
    public typealias Outcome = ClaudeReader.Result

    public let reader: ClaudeReader

    public init(reader: ClaudeReader) {
        self.reader = reader
    }

    public func pollOnce(now: Date) async throws -> ClaudeReader.Result {
        // ClaudeReader.read is synchronous (file I/O). Run on a background actor
        // so we don't block the calling task.
        try await Task.detached { [reader] in
            try reader.read(now: now)
        }.value
    }

    public func makeSnapshot(from outcome: ClaudeReader.Result, now: Date) -> UsageSnapshot? {
        outcome.snapshot
    }

    public func unconfiguredReason(from outcome: ClaudeReader.Result) -> UnconfiguredReason? {
        // No way to tell from current ClaudeReader.Result whether the directory
        // was inaccessible (FDA blocked) vs empty. Phase 2 task #9 adds a
        // dedicated TCC probe. For now: if no snapshot and zero files scanned,
        // we treat that as "FDA not granted" (best-effort hint).
        if outcome.snapshot == nil && outcome.filesScanned == 0 {
            return .missingFullDiskAccess
        }
        return nil
    }

    public func failureReason(from error: Error) -> MonitorFailureReason {
        .fileSystemError(message: "\(error)")
    }
}

public extension BaseServiceMonitor where Reader == ClaudeReaderAdapter {
    /// Convenience constructor that wires `ClaudeReader` into a monitor with
    /// sensible defaults.
    static func claude(
        store: StateStore,
        reader: ClaudeReader,
        interval: TimeInterval = Tokens.Polling.defaultIntervalSeconds,
        scheduler: SchedulerProvider = DispatchQueueMainScheduler()
    ) -> BaseServiceMonitor<ClaudeReaderAdapter> {
        BaseServiceMonitor<ClaudeReaderAdapter>(
            serviceID: .claude,
            store: store,
            reader: ClaudeReaderAdapter(reader: reader),
            interval: interval,
            scheduler: scheduler
        )
    }
}
