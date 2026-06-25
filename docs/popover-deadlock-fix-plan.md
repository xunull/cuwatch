# Popover Deadlock & Concurrency Hardening Plan

**Status**: PR 1 (#1+#3+#3b) + #2 implemented and tested 2026-06-25
— deadlock fix shipped, plan complete
**Diagnosed in**: `/gstack-investigate` session, 2026-06-25
**Reviewed in**: `/gstack-plan-eng-review` session, 2026-06-25 (13 findings, all
absorbed)
**Sister doc**: [`docs/claude-statusline-rate-limits.md`](./claude-statusline-rate-limits.md) (separate scope)

---

## TL;DR

cuwatch's menu bar icon went unresponsive after ~4 days uninterrupted runtime
(PID 22558, launched 2026-06-21 18:05). Root cause: `PopoverViewModel`'s two
Combine sinks have no `.receive(on:)`, so they execute on whichever background
thread fired the publisher. The three `ServiceMonitor` instances each poll on
their own cooperative-pool worker; when two of them write to `StateStore` at
nearly the same time, two threads concurrently mutate `pendingFlushToken`
(a plain `ScheduledWork?` stored property) and trigger
`DispatchScheduledWork.deinit` while Combine's `@Published` unfair_lock is
still held. The cleanup path takes ObjC runtime's `realizeIfNeeded` lock, and
the two locks deadlock against each other. Once stuck, the cooperative pool
fills, the main thread's own `@Published` chain blocks on the same Combine
lock, and the popover never appears even though the main thread itself is
idle in `mach_msg2_trap`.

This plan does five things in priority order: (1) hot-patch the sinks to
land on main; (2) prove the fix with `@MainActor`; (3) cut Codex's full-read
IO down 95% via mtime cache; (4) optional tail-read if mtime cache isn't
enough; (5) explicitly NOT actor-ize `BaseServiceMonitor` — the race wasn't
inside it.

---

## Incident summary

**Symptom**: Left-click on the menu bar icon produced no popover.
Right-click context menu still worked. App was alive — needle still
animated, monitors still polling, Activity Monitor not flagging
"Not Responding."

**Time to failure**: ~4 days continuous, debug Xcode run.

**Diagnostic command**: `/usr/bin/sample 22558 3`. Two cooperative-pool
worker threads showed identical stacks:

```
DispatchQueue_18: com.apple.root.user-initiated-qos.cooperative
  BaseServiceMonitor.scheduleNext.closure          (line 155)
  → BaseServiceMonitor.performPoll                  (line 114)
  → BaseServiceMonitor.handleSuccess                (line 133)
  → StateStore.update(monitorState:for:)            (line 47)
  → @Published.modify → PublishedSubject.send
  → PopoverViewModel.enqueueMonitorStateChange      (line 91)
  → PopoverViewModel.schedulePendingFlush           (line 130)
  → outlined assign with take of ScheduledWork?
  → DispatchScheduledWork.__deallocating_deinit
  → objc_class::realizeIfNeeded
  → __ulock_wait2                                   ← stuck
```

A second worker was stuck at `PublishedSubject.send →
_os_unfair_lock_lock_slow`. The main thread itself was idle at
`mach_msg2_trap` — the deadlock was NOT on the main thread, but on
background workers holding the locks the main thread needed.

---

## Root cause

Two locations.

### A. `Sources/CuwatchCore/State/PopoverViewModel.swift:82-93`

```swift
stateStore.$snapshots
    .dropFirst()
    .sink { [weak self] new in
        self?.enqueueSnapshotChange(new)
    }
    .store(in: &cancellables)

stateStore.$monitorStates
    .dropFirst()
    .sink { [weak self] new in
        self?.enqueueMonitorStateChange(new)
    }
    .store(in: &cancellables)
```

No `.receive(on:)` before either `.sink`. The closure runs on whichever
thread mutated the publisher.

### B. `Sources/CuwatchCore/State/PopoverViewModel.swift:126-133`

```swift
private func schedulePendingFlush() {
    pendingFlushToken?.cancel()
    pendingFlushToken = scheduler.schedule(after: coalesceDebounce) { ... }
}
```

`pendingFlushToken: ScheduledWork?` is a plain stored property. The
cancel-then-assign pair is not atomic. The old `ScheduledWork` is released
as a side effect of the assignment, triggering `deinit` synchronously on
whichever thread wins the assign race.

### How it stalls

The threading model has two layers:

```
BaseServiceMonitor.scheduleNext(after:)
  └ scheduler.schedule(after:)
      └ DispatchQueue.main.asyncAfter            ← timer fires on MAIN queue
          └ closure body runs on main
              └ Task { await self.performPoll() }   ← unstructured Task
                  └ inherits no actor isolation
                  └ runs on COOPERATIVE pool
                      └ performPoll → handleSuccess
                      └ StateStore.update          ← mutation here
                      └ @Published.modify          ← lock held here
                      └ sink runs on cooperative   ← race surface
```

So the timer fires on main, but the actual work (and the @Published
mutation) happens on cooperative-pool workers. Three monitors → up to
three workers concurrently mutating `StateStore`.

When two monitors fire `StateStore.update(...)` near-simultaneously,
the evidence is consistent with one of these scenarios:

1. Thread A enters `@Published.modify`, takes Combine's internal
   unfair_lock, starts notifying subscribers.
2. Subscriber chain reaches `PopoverViewModel.enqueueMonitorStateChange`
   on Thread A.
3. Thread A enters `schedulePendingFlush`, releases the OLD
   `ScheduledWork`. ARC fires `DispatchScheduledWork.deinit`
   synchronously.
4. `deinit` chain calls `objc_class::realizeIfNeeded` — takes the ObjC
   runtime's class-realization unfair_lock.
5. Meanwhile Thread B has entered `@Published.modify` from another
   monitor and is on a similar deinit path, also waiting on the ObjC
   realization lock.
6. The third party holding the realization lock is itself blocked
   (sample only captured 3 seconds — we never saw who held the lock),
   creating one of: A↔B mutual wait, a starvation loop where the
   holder can't get CPU time on a saturated cooperative pool, or a
   circular dependency between the Combine internal lock and the ObjC
   realization lock.

**Important**: the exact mechanism is a strong hypothesis, not proven —
we'd need to capture the lock holder to be certain. But the fix
(`.receive(on: DispatchQueue.main)`) eliminates all three scenarios
because it eliminates the concurrent mutation in the first place. We
don't need to identify the precise lock cycle to fix it.

The window is microseconds, so it takes days of every-30s polling
across three monitors for the timing to align. Once the two cooperative
workers are stuck:

- All subsequent `performPoll()` tasks queue behind them — the
  cooperative pool is sized roughly to CPU cores.
- The main thread's own `@Published` subscribers
  (`bindStateStoreToDial` chain, `cuwatch/cuwatch/AppDelegate.swift:277-286`)
  need the same Combine lock — they block.
- Click → `togglePopover` → `popover.show` → SwiftUI hosting controller
  reads `popoverViewModel.snapshots` → blocks on the same lock →
  popover never appears.

### Why CodexReader makes it worse but is not the cause

Commit `af0e885` added `makeSnapshotFromRateLimits()`, which reads the 5
most-recent `~/.codex/sessions/**/rollout-*.jsonl` files in full per
poll. The directory currently holds **132 files / 752 MB**, with the
top 5 averaging ~30 MB each. Each poll therefore burns:

- ~150 MB of disk IO
- A `Data` allocation, a `String` conversion, an Array<Substring> from
  `split("\n")`, and N `JSONSerialization.jsonObject` calls per file
- Hundreds of milliseconds of cooperative-worker CPU time

This is not the root cause — the race would exist with any non-trivial
concurrent mutation — but it dramatically widens the race window. With
the pre-`af0e885` time-proxy code, the bug likely takes weeks instead
of days. Fixing the race makes the IO load wasteful but no longer
load-bearing for correctness.

---

## The plan

Five items, sequenced. #1-#3 are required. #4 is conditional. #5 is
explicitly out of scope.

### #1 — Hot patch: `.receive(on: DispatchQueue.main)` on both sinks

| Field | Value |
|---|---|
| File | `Sources/CuwatchCore/State/PopoverViewModel.swift:82-93` |
| Lines changed | 2 (one `.receive(on:)` per sink) |
| Test added | 1 — concurrent enqueue stress test |
| Risk | Low |
| Priority | Immediate |

**What**: Insert `.receive(on: DispatchQueue.main)` before `.sink` on
both subscriptions:

```swift
stateStore.$snapshots
    .dropFirst()
    .receive(on: DispatchQueue.main)   // ← new
    .sink { [weak self] new in ... }
```

**Why this works**: Forces every `enqueueSnapshotChange` /
`enqueueMonitorStateChange` call onto the main queue. `schedulePendingFlush`
then mutates `pendingFlushToken` on a single thread. No race, no deadlock.

**Why it's behaviorally safe**: `AppDelegate` injects
`DispatchQueueMainScheduler()` into `PopoverViewModel`
(`cuwatch/cuwatch/AppDelegate.swift:36-41`), so in production the
eventual `flushNow()` already runs on main. The enqueue itself was
supposed to be a no-op timing-wise — this just makes it so in fact.

(`PopoverViewModel`'s own default scheduler is `ImmediateMainScheduler`,
which runs work synchronously on the calling thread. That's a test-only
fallback; production never sees it because `AppDelegate` overrides it.
The synchronous default is also why **test-side stress tests MUST inject
`DispatchQueueMainScheduler` explicitly** — see test spec below.)

**Test** (`Tests/CuwatchCoreTests/PopoverViewModelConcurrencyTests.swift`):

```
testConcurrentEnqueueDoesNotDeadlock
  Given: PopoverViewModel + StateStore wired as production does, with
         scheduler EXPLICITLY set to DispatchQueueMainScheduler()
         (NOT the test default of ImmediateMainScheduler — that would
         hide the race by running synchronously on the calling thread)
  When:  100 concurrent tasks across 4 background queues each call
         stateStore.publish(snapshot:) and stateStore.update(monitorState:)
         repeatedly for 0.5 seconds
  Then:  the test drains within a 5-second hard cap
   And:  no XCTestExpectation times out
   And:  final snapshots/monitorStates reflect the last writes
   And:  a thread-recording probe inside PopoverViewModel observes
         all mutations on the main thread (zero non-main mutations)
```

**Acceptance**: Test passes; manual sample on a freshly-launched build
under 30s of artificial monitor pressure shows zero `__ulock_wait2`
frames on cooperative workers.

---

### #2 — Type-system fix: `@MainActor` on `PopoverViewModel`

| Field | Value |
|---|---|
| File | `Sources/CuwatchCore/State/PopoverViewModel.swift` |
| Lines changed | ~20-30 |
| Test added | 1 — runtime confirmation that mutations happen on main |
| Risk | Medium |
| Priority | Day 1-2 |

**What**: Mark `final class PopoverViewModel` as `@MainActor`.

**Why**: #1 is a runtime guarantee. A future contributor who adds a new
subscriber and forgets `.receive(on:)` re-introduces the same bug.
`@MainActor` makes the compiler enforce single-threaded mutation. SwiftUI
views are already `@MainActor`-isolated, so the view layer needs no change.

**Relationship to #1**: keep the explicit `.receive(on: DispatchQueue.main)`
even after `@MainActor` lands. Runtime cost is zero (a publisher already
on main skips the hop), and it acts as defense in depth — if a future
PR mistakenly removes the `@MainActor` annotation, the runtime guard
is still in place. Add a one-line comment at the `.receive(on:)` site
explaining both layers exist on purpose.

**Call-site audit is compiler-driven, not manual**:
- Mark `final class PopoverViewModel: ObservableObject` as `@MainActor`.
- Run `swift build` + Xcode build for both the SwiftPM library and the
  app target.
- Every compile error is an audit hit. Fix each:
  - SwiftUI view sites WON'T error (`View` protocol is already
    `@MainActor`-isolated).
  - `cuwatch/cuwatch/AppDelegate.swift:277-286` — `bindStateStoreToDial`
    chain. Already in `applicationDidFinishLaunching` (main); the
    Combine sink closure may need `MainActor.assumeIsolated { ... }` if
    the compiler can't prove main isolation through the sink.
  - `Tests/CuwatchCoreTests/PopoverViewModel*Tests.swift` — XCTest's
    default queue is not main. Tests calling
    `flushPendingForTesting()` synchronously need:
    ```swift
    MainActor.assumeIsolated { vm.flushPendingForTesting() }
    // or, in async tests:
    await MainActor.run { vm.flushPendingForTesting() }
    ```
- Stop auditing when compile is clean. The compiler is the authority,
  not this checklist.

**Test** (`Tests/CuwatchCoreTests/PopoverViewModelMainActorTests.swift`):

```
testEnqueueFromBackgroundQueueIsScheduledOnMain
  Given: PopoverViewModel with a probe that records the thread of every
         internal mutation
  When:  stateStore.publish(...) is called from DispatchQueue.global()
  Then:  within 100ms the probe recorded one main-thread mutation
   And:  zero non-main-thread mutations
```

**Risk**: Medium. Public API surface changes. Tests calling public
methods synchronously need wrapping. Verify Swift toolchain supports
`MainActor.assumeIsolated` (Swift 5.9+) — if not, fall back to
`await MainActor.run { ... }`.

**Acceptance**: Project compiles; all 189 existing tests still pass
(with wrappers added where needed); new test passes; manual smoke
(launch + click + change Minimax endpoint + change poll interval) works.

---

### #3 — `CodexReader` mtime + size cache

| Field | Value |
|---|---|
| File | `Sources/CuwatchCore/Services/Codex/CodexReader.swift:208-256` |
| Lines changed | ~40-60 |
| Test added | 2 (hit, invalidation) |
| Risk | Low |
| Priority | Day 0-1 (can ship with #1) |

**What**: Add an in-memory cache keyed by `URL`, valued by
`(mtime, size, lastRateLimits)`. Before opening a file in
`makeSnapshotFromRateLimits`:

1. `fileManager.attributesOfItem(atPath:)` → `(mtime, size)`
2. If `cache[url]?.mtime == mtime && cache[url]?.size == size`,
   reuse cached `CodexRateLimits` — no IO, no parse.
3. Otherwise read + parse + update cache.

Cache lives on the `CodexReader` instance. Since one `CodexReader` is
created per `AppDelegate` and lives for the app lifetime, the cache
persists for the whole session.

```swift
struct CodexRateLimitsCacheEntry {
    let mtime: Date
    let size: Int
    let lastRateLimits: CodexRateLimits?  // nil = file had no rate_limits
}

private var rateLimitsCache: [URL: CodexRateLimitsCacheEntry] = [:]
```

**Why**: The 132 rollout files in `~/.codex/sessions` are almost all
*immutable* — codex CLI writes one rollout per session and never reopens
old ones. Re-reading them every 30s wastes ~150MB of IO and ~50MB of
allocator churn per poll. Cache hit rate at steady state should be
>95% — only the currently-active rollout file changes mtime within a
30s interval.

**Concurrency note**: there is exactly one `CodexReader` instance per
`AppDelegate`, polled by exactly one `BaseServiceMonitor<CodexReaderAdapter>`.
The cache dictionary is mutated only from that monitor's poll path —
no shared-mutable-state concurrency. Document this explicitly in a
comment above `rateLimitsCache` so a future refactor that introduces a
second reader doesn't silently race.

**Tests** (`Tests/CuwatchCoreTests/CodexReaderCacheTests.swift`):

```
testCacheHitSkipsFileRead
  Given: CodexReader has read a rollout file once
  When:  the file's mtime and size are unchanged
  Then:  the second read returns the same CodexRateLimits
   And:  an instrumented FileManager subclass records read_count == 1

testCacheInvalidationOnMtimeChange
  Given: a cached entry for a rollout file
  When:  the file is rewritten with new content (new mtime/size)
  Then:  the next read produces fresh CodexRateLimits
   And:  the cache entry's mtime/size match the new file

testCacheHandlesDeletedFile
  Given: a cached entry for a rollout file
  When:  the file is deleted (codex log rotation, user cleanup)
  Then:  attributesOfItem throws; the cache entry is evicted
   And:  the read returns nil (or the next-most-recent cached entry)
   And:  no crash, no propagated error to the monitor
```

**Risk**: Low. The cache is a pure IO short-circuit; if a key check
goes wrong (mtime stays the same despite content change), the worst
case is stale rate_limits for one polling interval. Filesystem
mtime+size collisions on a 30s cadence are astronomically unlikely.

**Acceptance**: Tests pass; sample of cuwatch under steady-state shows
Codex `performPoll` CPU time drops by >90%.

---

### #3a — Persist cache across restarts (DEFERRED — not in scope)

**Decision**: Out of scope for this plan. Reconsidered during eng review
2026-06-25.

**Reasoning**:
- Cold-start cost without persistence is ~3-5s of IO on the first
  Codex poll. This is a **one-time cost per app launch**.
- For a menu-bar daemon that runs for days at a time, that one-time
  cost amortizes to invisible.
- Persistence introduces new failure surfaces: corrupted JSON,
  permission errors, disk-full, schema drift on future cache shape
  changes, and ~50k disk writes/year from the debounce window.
- Memory cache (#3) already solves the steady-state IO problem.

**Re-open trigger**: if real user reports show launch-to-first-popover
exceeds 2s noticeably, revisit. Capture as a TODO comment in
`CodexReader.swift` near the cache declaration: `// TODO: persist cache
across restarts if launch perf becomes a complaint`.

---

### #3b — Move Codex IO off the cooperative pool

| Field | Value |
|---|---|
| File | `Sources/CuwatchCore/Services/Codex/CodexReader.swift` (`makeSnapshotFromRateLimits` call site, or `CodexReaderAdapter.pollOnce`) |
| Lines changed | ~5-10 |
| Test added | 0 (behavior-preserving) |
| Risk | Low |
| Priority | Same PR as #3 |

**What**: Wrap the synchronous IO + JSON parse in
`Task.detached(priority: .utility) { ... }` and `await` the result.

```swift
public func pollOnce(now: Date) async throws -> CodexReader.Result {
    try await Task.detached(priority: .utility) { [reader = self.reader] in
        reader.read(now: now)
    }.value
}
```

(Exact location depends on where `CodexReader.read(now:)` is called from
the adapter — the adapter is the right boundary for the hop.)

**Why**: Swift concurrency's cooperative thread pool is sized to roughly
`max(2, CPU cores - 1)` (~8 on modern Macs). When #3's cache misses
(the active rollout file changed mtime), `CodexReader.read` does
synchronous IO + JSON parse for up to ~50 MB before returning. That
blocks a cooperative worker. With three monitors and three workers in
the pool, a slow Codex read can starve Claude/Minimax monitors of
runtime.

`Task.detached(priority: .utility)` puts the work on a **separate**
QoS-utility pool that's specifically sized for IO/compute, not on the
cooperative pool the Swift runtime uses for `async let` and inherited
Tasks. The cooperative pool stays free.

**Behavior preservation**: the work is identical, only its execution
queue changes. No test changes needed; existing CodexReader tests still
pass because they call `read(now:)` directly (sync), not through the
adapter.

**Risk**: Low. `Task.detached` is documented Swift concurrency. The only
gotcha is that `[reader = self.reader]` capture is needed if the adapter
is non-Sendable; verify `CodexReader` is `Sendable` (or mark it so) — it's
a final class with immutable stored properties + an internal cache
dictionary, so `@unchecked Sendable` with a doc comment explaining the
single-monitor invariant from #3 is fine.

**Acceptance**: Sample under steady-state shows Codex work appears in
`com.apple.root.utility-qos.cooperative` (or equivalent utility-pool
queue), not in `com.apple.root.user-initiated-qos.cooperative`.

---

### #4 — Tail-read for the active rollout file (optional, deferred)

| Field | Value |
|---|---|
| File | `Sources/CuwatchCore/Services/Codex/CodexReader.swift` (the `lastRateLimits(in:)` static) |
| Lines changed | ~30-40 |
| Test added | 1 |
| Risk | Medium |
| Priority | Conditional — only if #3 isn't enough |

**What**: For files where the cache misses (i.e. the actively-growing
rollout), replace `try? Data(contentsOf: url)` + full split with a
reverse-tail read: seek to EOF, read the last ~256KB into a buffer,
scan backwards for the last newline-delimited line containing
`"rate_limits"`, parse just that line.

**Why**: The active rollout file's cache entry invalidates on every
codex CLI invocation. If that file grows to 50MB+ during a long
session, even with #3 we re-read 50MB per cache miss. Tail-read makes
the cost constant in file size.

**When to do this**: Only if instrumentation after #3 ships shows the
active-rollout path is still dominating poll time. The hypothesis is
that it won't — the active file is typically <2MB until many events
have accumulated.

**Risk**: Medium. Backward JSONL scanning needs careful handling of:
- Files smaller than the tail window (just read the whole thing)
- Files mid-write with a partial trailing line (skip to previous
  newline)
- The case where `rate_limits` appears in a different field's value
  (use a stricter regex anchor, e.g. `"payload":\s*{[^}]*"rate_limits"`)

**Acceptance**: Only worth implementing if a measurement justifies it.
Defer until then.

---

### #5 — Do NOT actor-ize `BaseServiceMonitor`

**Decision**: Explicitly out of scope.

**Reasoning**: `BaseServiceMonitor` already serializes its mutable
state with `queue.sync` (see `Sources/CuwatchCore/Services/BaseServiceMonitor.swift`,
lines 75, 81-86, 91-96, 101-104, 126, 151-152, 157). The deadlock was
*upstream* of it — in `PopoverViewModel`'s sink, which
`BaseServiceMonitor` doesn't control. Converting `BaseServiceMonitor`
to a Swift `actor` would:

- Force all call sites to become `await` (3 monitor factories in
  `AppDelegate.swift`, plus `restartAllMonitors`)
- Require re-thinking `ScheduledWork` ownership across actor boundaries
- Diverge from `StateStore` (still a regular class), which holds the
  same kind of mutable state
- Solve no known bug

Revisit only if a future bug clearly traces to a mutable-state race
*inside* `BaseServiceMonitor` itself.

---

## Sequencing

1. **Day 0 — same PR**: #1 + #3 + #3b. Sink hop fix unblocks the
   immediate symptom; Codex mtime cache removes the accelerant;
   detached-Task hop keeps Codex IO off the cooperative pool. Together
   they make a 4-day repro impossible AND fix the upstream pressure
   that lengthened the race window.
2. **Day 1-2 — separate PR**: #2. `@MainActor` audit. Standalone
   review because it changes API surface.
3. **Conditional**: #4 only if measurement after #3 shows the active
   rollout still dominates poll time.
4. **Out of scope**: #3a (deferred — see its section), #5.

Rationale for bundling #1 + #3 + #3b in one PR: #3 alone is a perf
improvement; #1 alone is the deadlock fix but Codex IO remains
wasteful; #3b alone is pointless without #3. Together they're a
coherent "cuwatch should be polite to the user's filesystem AND not
deadlock AND not starve other monitors" change. The PR description
should explain all three.

## Validation

How we know the fix held. Each acceptance is concrete and ownable —
no hand-waving.

### V1 — Synthetic stress test (CI)

A unit test that simulates 4 days of polling in 4 minutes (drop the 30s
interval to 0.01s in a test build, drive `StateStore.update` from 4
concurrent queues for 240 seconds, watch for deadlock via
XCTestExpectation timeout). Ship this in CI as part of #1.

The test MUST inject `DispatchQueueMainScheduler` (not the
`ImmediateMainScheduler` test default) — see #1 test spec.

### V2 — Thread Sanitizer pass

Run the full test suite under TSan after #1 lands. In Xcode:
`Product → Scheme → Edit Scheme → Run → Diagnostics → Thread Sanitizer`.
For SwiftPM: `swift test -Xswiftc -sanitize=thread`.

Acceptance: zero TSan warnings related to `PopoverViewModel`,
`StateStore`, or `BaseServiceMonitor`. TSan is slow (2-5× test runtime)
so don't add it to default CI; run it manually after #1 and #2 ship,
and as a periodic check.

### V3 — Performance baseline (Codex poll wall-clock)

Measure Codex `performPoll` wall-clock time before and after #3+#3b on
the same `~/.codex/sessions`. Concrete protocol:

```bash
# Before patch — capture 10 poll cycles, look for the IO call
/usr/bin/sample <PID> 300 | grep -E "makeSnapshotFromRateLimits|read.*Data" | head

# After patch — same command, 10 cycles
# Expected: zero hits at steady state (cache hits skip the function entirely
# for the 4 idle rollout files; the active file hits #3b's utility queue,
# not the cooperative pool we're sampling)
```

Acceptance: >90% reduction in Codex IO frames observed in the sample.
Capture both numbers in the PR description.

### V4 — Cold start performance

After #3 lands (no persistence per #3a deferral), cold-start cost is
3-5s of IO on first Codex poll. After full app startup, the FIRST
popover open should still feel instant because Codex is one of three
monitors and the dial is already drawn from cached state.

Acceptance: `App launch → status item visible` within 200ms (warm
build); `status item click → popover visible` within 100ms regardless
of Codex monitor state.

### V5 — Production proof (author dogfood, 14 days)

Author (`xunull`, this repo's solo maintainer) runs the patched build
continuously on a daily-driver Mac for 14 days. The cuwatch process
must remain responsive to left-click the entire window. Sample at day
7 and day 14:

```bash
sample $(pgrep -fx 'cuwatch') 3
```

Acceptance: zero `__ulock_wait2` frames on cooperative-pool workers in
either sample. Author records pass/fail in the PR follow-up comment.

## Non-goals

- **Does not** add a real-time Claude row. That's a separate epic; see
  [`docs/claude-statusline-rate-limits.md`](./claude-statusline-rate-limits.md).
- **Does not** address the broader question of cuwatch's data-source
  strategy across the three services. That belongs in a future office-hours.
- **Does not** clean up `~/.codex/sessions`. We treat that directory
  as read-only and defend against its growth.
- **Does not** change `DESIGN.md` or any UI behavior. The fix is
  purely concurrency + IO.
- **Does not** justify a `v0.1.0` bump on its own. This is a `v0.0.x`
  patch.

## Open questions

1. **Cache cap?** At 132 entries today, growing linearly with
   `.codex/sessions`. Each entry is one-per-file, ~50 bytes; even
   10K entries is <1MB. **Resolution**: no cap. The cache is naturally
   bounded by the number of jsonl files on disk, which is bounded by
   the user's codex usage. The cache is purged of entries pointing at
   missing files at load time (via the `testCacheHandlesDeletedFile`
   path).
2. **`MainActor.assumeIsolated` availability**: Swift 5.9+. Verify the
   project's Swift toolchain before starting #2; if not, use
   `await MainActor.run { ... }` in tests.
3. **`os_signpost` for verification**: yes for V3 measurement, then
   remove. Do NOT ship signposts in production — they leak internal
   timing to anyone running Instruments.
4. **Should #1's stress test be marked `@MainActor`?** No — it must
   exercise the BACKGROUND-thread path. Marking it `@MainActor` would
   defeat the test's purpose by serializing the test work itself.

### Resolved during eng review (2026-06-25)

- **#3a (cache persistence)**: deferred / out of scope. Cold-start
  cost is acceptable; persistence adds failure surfaces (corruption,
  permission, ~50k writes/year) and the daemon-style usage pattern
  hides the one-time cost.
- **#3b (Task.detached for IO)**: added to plan. Keeps Codex IO off
  the cooperative pool so a 50MB cache-miss read doesn't starve
  Claude/Minimax monitors.

## References

- Sample output: `/tmp/cuwatch_2026-06-25_091320_NTGn.sample.txt`
  (debug artifact, do not commit).
- `Sources/CuwatchCore/State/PopoverViewModel.swift` — file being
  fixed.
- `Sources/CuwatchCore/State/StateStore.swift` — the publisher source.
- `Sources/CuwatchCore/Services/BaseServiceMonitor.swift` — call-site
  context.
- `Sources/CuwatchCore/Services/Codex/CodexReader.swift` — file being
  optimized.
- `cuwatch/cuwatch/AppDelegate.swift` — main-thread integration.
- [`docs/claude-statusline-rate-limits.md`](./claude-statusline-rate-limits.md)
  — sister doc, separate scope.

---

**Last updated**: 2026-06-25 v2 — absorbed 13 findings from
`/gstack-plan-eng-review` session (3 factual corrections, 4 architecture
fixes including new #3b, 3 test additions, 3 validation strengthenings).
v1: initial draft from `/gstack-investigate` session same day.

## Revision log

- **v2 (2026-06-25)**: eng review absorbed. Threading model description
  corrected; deadlock mechanism downgraded to strong hypothesis; #1 test
  spec clarified on scheduler injection; #2 audit changed to
  compiler-driven; #3a deferred; #3b added (Task.detached for Codex IO);
  V2-V5 validation steps added with concrete acceptance criteria.
- **v1 (2026-06-25)**: initial diagnosis from `/gstack-investigate`.

---

## GSTACK REVIEW REPORT

| Run | Status | Findings | Notes |
|-----|--------|----------|-------|
| `/gstack-plan-eng-review` 2026-06-25 | absorbed | 13 / 13 | 3 factual, 4 architecture, 3 test, 3 validation |

**Findings absorbed**:

- E1: scheduler default value corrected (PopoverViewModel default is
  `ImmediateMainScheduler`, not `DispatchQueueMainScheduler`)
- E2: threading model layered explanation (timer fires on main, Task
  body runs on cooperative pool)
- E3: deadlock mechanism downgraded from "is" to "evidence consistent
  with one of three scenarios"; fix correctness explained independently
- A1: #1 and #2 relationship clarified (keep `.receive(on:)` as defense
  in depth after @MainActor lands)
- A2: #3b added — wrap Codex IO in `Task.detached(priority: .utility)`
  to keep it off the cooperative pool
- A3: #2 audit changed from file list to compiler-driven workflow
- A4: #3a downgraded to deferred / out of scope with reopen trigger
- T1: #1 test spec amended to require explicit `DispatchQueueMainScheduler`
  injection (not the synchronous test default)
- T2: V2 — Thread Sanitizer validation added
- T3: `testCacheHandlesDeletedFile` added to #3 tests
- P1: V3 — Codex perf baseline quantified with concrete sample commands
- P2: V4 — cold start + popover open acceptance bounds added (200ms /
  100ms)
- P3: V5 — author named as 14-day dogfood owner, sample commands written

**VERDICT**: DONE_WITH_CONCERNS → DONE. All 13 findings absorbed. Plan
ready for implementation. Next step: implement #1 + #3 + #3b as a
single PR; #2 follows in a separate PR.

NO UNRESOLVED DECISIONS
