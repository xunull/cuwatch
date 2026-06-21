import Foundation

/// Persistent on-disk history of usage events, used to compute burn rate (v1.1)
/// and display short-term trends.
///
/// File: `~/Library/Application Support/cuwatch/history.json`.
/// Schema documented in the project plan; events are append-only with a rolling
/// 30-day prune window (default).
///
/// Write contract — atomic (per plan NFR + /plan-eng-review):
///   1. Serialize to `history.json.tmp`
///   2. `fsync` the tmp file
///   3. `rename` tmp → final
///
/// If the process crashes mid-write, the next launch sees an orphan `.tmp` file
/// that `cleanupOrphans()` deletes if older than 5 minutes.
public final class HistoryStore {

    // MARK: - Public API

    public struct Event: Codable, Equatable, Sendable {
        public let ts: Date
        public let service: ServiceID
        public let tokensIn: Int
        public let tokensOut: Int
        public let costUSD: Double?
        public let modelID: String
        public let sessionID: String?

        public init(
            ts: Date,
            service: ServiceID,
            tokensIn: Int,
            tokensOut: Int,
            costUSD: Double?,
            modelID: String,
            sessionID: String? = nil
        ) {
            self.ts = ts
            self.service = service
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.costUSD = costUSD
            self.modelID = modelID
            self.sessionID = sessionID
        }

        // CodingKeys to match the documented schema (snake_case on disk).
        enum CodingKeys: String, CodingKey {
            case ts
            case service
            case tokensIn = "tokens_in"
            case tokensOut = "tokens_out"
            case costUSD = "cost_usd"
            case modelID = "model_id"
            case sessionID = "session_id"
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var version: Int
        public var events: [Event]

        public init(version: Int = 1, events: [Event] = []) {
            self.version = version
            self.events = events
        }
    }

    /// Directory housing `history.json`. Override for tests.
    public let directoryURL: URL

    public init(directoryURL: URL? = nil) throws {
        if let url = directoryURL {
            self.directoryURL = url
        } else {
            self.directoryURL = try Self.defaultDirectoryURL()
        }
        try FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent("history.json")
    }

    /// Load the file. Missing file → returns empty `File`. Corrupt file → throws and
    /// caller should rename it out of the way (see `quarantineCorruptFile`).
    public func load() throws -> File {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return File()
        }
        let data = try Data(contentsOf: url)
        let decoder = makeDecoder()
        return try decoder.decode(File.self, from: data)
    }

    /// Save atomically: serialize → write `.tmp` → fsync → rename. Never leaves a half-written
    /// `history.json` even on crash.
    public func save(_ file: File) throws {
        let encoder = makeEncoder()
        let data = try encoder.encode(file)

        let tmpURL = directoryURL.appendingPathComponent("history.json.tmp")
        // Write to tmp.
        let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw HistoryStoreError.tmpWriteFailed(errno: errno)
        }
        defer { close(fd) }

        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            var remaining = rawBuffer.count
            var ptr = rawBuffer.baseAddress!
            while remaining > 0 {
                let written = write(fd, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw HistoryStoreError.tmpWriteFailed(errno: errno)
                }
                remaining -= written
                ptr = ptr.advanced(by: written)
            }
        }

        // fsync.
        if fsync(fd) != 0 {
            throw HistoryStoreError.fsyncFailed(errno: errno)
        }

        // Rename tmp → final (atomic on POSIX same-fs).
        try FileManager.default.replaceItem(
            at: fileURL,
            withItemAt: tmpURL,
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )
    }

    /// Move a corrupt `history.json` aside so the next launch can start fresh.
    public func quarantineCorruptFile() throws {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dateStr = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantine = directoryURL.appendingPathComponent(
            "history.broken-\(dateStr).json"
        )
        try FileManager.default.moveItem(at: url, to: quarantine)
    }

    /// Remove any `*.tmp` orphans older than `maxAge` (default 5 min).
    /// Call at app launch.
    @discardableResult
    public func cleanupOrphans(maxAge: TimeInterval = 5 * 60, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var deleted = 0
        for url in entries {
            guard url.pathExtension == "tmp" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let mtime else { continue }
            if now.timeIntervalSince(mtime) > maxAge {
                if (try? fm.removeItem(at: url)) != nil {
                    deleted += 1
                }
            }
        }
        return deleted
    }

    /// Prune events older than `keepDays`. Default 30 (per plan).
    public func prune(file: File, keepDays: Int = 30, now: Date = Date()) -> File {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 24 * 60 * 60)
        var pruned = file
        pruned.events = file.events.filter { $0.ts >= cutoff }
        return pruned
    }

    // MARK: - Internals

    public static func defaultDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("cuwatch", isDirectory: true)
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum HistoryStoreError: Error, Equatable {
    case tmpWriteFailed(errno: Int32)
    case fsyncFailed(errno: Int32)
    case renameFailed(errno: Int32)
}
