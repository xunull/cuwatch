import Foundation

/// In-memory mtime-keyed cache of parsed JSONL records.
///
/// Per /plan-eng-review D5: re-parsing all `~/.claude/projects/*.jsonl` files
/// on every 30s poll is unacceptable (potentially hundreds of MB of I/O). The
/// cache lets us:
///
/// 1. `stat` the full set of files in the projects directory — cheap, ~1ms
///    even with 100 files.
/// 2. For each file, compare its current `mtime` against the cached value.
/// 3. Re-parse only files whose `mtime` has advanced.
/// 4. Use cached records for unchanged files.
/// 5. Drop cache entries for files that have been deleted.
/// 6. Initialize cache entries for newly-discovered files (parsed from scratch).
///
/// Performance budget (M1 Air, 100 files / 50 MB total):
/// - Cold start (first poll): ≤ 2 s to parse everything
/// - Steady state (no changes): ≤ 10 ms (stat-only)
/// - Single-file change (5 MB): ≤ 100 ms
///
/// Thread-safety: not thread-safe. Owning `ClaudeReader` calls into the cache
/// from a single serial queue.
public final class JSONLFileCache {

    public struct Entry: Equatable {
        public let mtime: Date
        public let records: [ClaudeUsageRecord]
        public let lineCount: Int
        public let malformedLines: Int
    }

    private var entries: [URL: Entry] = [:]

    public init() {}

    // MARK: - CRUD

    public subscript(url: URL) -> Entry? {
        get { entries[url] }
    }

    public func upsert(url: URL, mtime: Date, parse: ClaudeJSONLParser.ParseResult) {
        entries[url] = Entry(
            mtime: mtime,
            records: parse.records,
            lineCount: parse.totalLines,
            malformedLines: parse.malformedLines
        )
    }

    public func remove(url: URL) {
        entries[url] = nil
    }

    /// Drop entries for any URL not in `livePaths`. Returns the number removed.
    @discardableResult
    public func prune(livePaths: Set<URL>) -> Int {
        let removed = entries.keys.filter { !livePaths.contains($0) }
        for url in removed { entries[url] = nil }
        return removed.count
    }

    // MARK: - Aggregates

    public var allRecords: [ClaudeUsageRecord] {
        entries.values.flatMap(\.records)
    }

    public var fileCount: Int { entries.count }

    public var totalLineCount: Int {
        entries.values.reduce(0) { $0 + $1.lineCount }
    }

    public var totalMalformedLines: Int {
        entries.values.reduce(0) { $0 + $1.malformedLines }
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
