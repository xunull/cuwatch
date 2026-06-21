# cuwatch

A macOS menu bar utility that aggregates current AI service usage —
Claude Code Plan, Codex CLI on ChatGPT Plus/Pro, and Minimax Token Plan —
into a single analog dial.

```
                  ┌─────────────────────────────────┐
                  │   CLAUDE · 5h window      38%   │
                  │   ▓▓▓▓▓▓▓░░░░░░░░░░░░  resets in │
                  │                          3h 07m │
                  │                                 │
                  │   CODEX · 5h window       12%   │
                  │   ▓▓░░░░░░░░░░░░░░░░░░  resets in │
                  │                          4h 24m │
                  │                                 │
                  │   MINIMAX · token plan     3%   │
                  │   ░░░░░░░░░░░░░░░░░░░░  resets in │
                  │                          5h 00m │
                  │                                 │
                  │   Updated 12s ago  Preferences  Quit │
                  └─────────────────────────────────┘
                              ▲
                       click the menu bar dial
```

The wedge: **the AI usage tracker that refuses to look like an AI tool**.
1960s analog instrument aesthetic. Warm-neutral palette. Single brass accent.
No vendor color coding. No SaaS template hero section.

## Why this exists

If you use Claude Code, Codex CLI, *and* a Chinese LLM, you tab between three
different dashboards to answer one question: "can I keep going right now, or
am I about to hit a wall?" cuwatch answers that with one glance at the menu bar.

Most existing tools either (a) focus on a single vendor, (b) read like generic
SaaS templates, or (c) have no design at all. cuwatch covers the three services
in one place and tries to look like something a person made on purpose —
not something an AI generated from a Hero/Features/CTA scaffold.

## What works today (v0.0.1)

### Data sources, ranked by accuracy

| Service | Source | Accuracy |
|---------|--------|----------|
| Minimax | HTTPS API `/v1/token_plan/remains` | **Real-time**, same number as Minimax console |
| Codex | `payload.rate_limits.primary.used_percent` from `~/.codex/sessions/**/rollout-*.jsonl` | **Stale snapshot.** Real numbers from OpenAI, but only refreshed when `codex` CLI runs. Desktop-only users will see hours-to-weeks-old data. |
| Claude | Time elapsed within detected 5h session window | **Time-based proxy**, NOT real token usage |

#### Honest disclosure (2026-06-21 spike findings)

`rate_limits` data is not persisted anywhere reusable by an outside app:

- **Anthropic** exposes Claude `rate_limits` only at runtime to statusline scripts, not to disk. cuwatch falls back to "you've been in a 5h session for N minutes → estimate N/300 used". This is **not how Claude bills you** and can diverge significantly from reality.
- **OpenAI Codex desktop app** fetches rate_limits **live from a private API** each time it displays them — nothing is cached to local disk (verified: Codex's three SQLite DBs at `~/.codex/{state_5,logs_2,sqlite/codex-dev}.sqlite`, the Chromium LevelDB at `~/Library/Application Support/Codex/Default/Local Storage/leveldb/`, the macOS NSURLCache at `~/Library/Caches/com.openai.codex/Cache.db`, and Cookies SQLite — none contain `rate_limits`). The codex **CLI** persists rate_limits per-response to rollout JSONL, which cuwatch reads — but only as fresh as your last CLI invocation.
- **Minimax** is the only vendor with a documented public quota endpoint. Hence the only row with real-time accuracy.

If you need a single number you can trust, watch the Minimax row.

### Service detail

- **Claude Code Plan** — reads `~/.claude/projects/**/*.jsonl`, detects the
  active 5h billing window using Anthropic's actual fixed-window semantics
  (not adjacent-gap heuristics), reports `elapsed / 5h` as used %.
  Accurate session WINDOW; inaccurate usage WITHIN the window.
- **Codex CLI on ChatGPT Plus/Pro** — filesystem probe against `~/.codex/`,
  parses `payload.rate_limits.primary.used_percent` + `resets_at` from the
  most-recent rollout JSONL event. The numbers shown are the SAME ones the
  Codex desktop app displays, **but only as fresh as the last time you ran
  `codex` from the CLI**. If you mostly use the desktop app, this row is stale.
  Plan tier (`plus`, `pro`) surfaces as the row's unit label.
- **Minimax Token Plan** — HTTPS GET against `api.minimaxi.com/v1/token_plan/remains`
  with Bearer token. Picks the most-constrained model across `model_remains[]`
  (e.g. `general` vs `video`) and shows that interval % as used.
- **Three failure-isolated monitors** with `BackoffSchedule [30, 60, 120, 300]`
  — one service going down doesn't take the dial neutral.
- **Single dial in the menu bar** with damped-spring needle (4° overshoot,
  280ms settle). Color ladder: brass `<70%` used, burnt orange `70-90%`,
  oxidized red `≥90%`. Respects Reduce Motion.
- **Popover dashboard** with header readout, three service rows, slide-in
  Preferences panel for Minimax token + endpoint + polling cadence.
- **Right-click menu bar** → Quit + Open. **Left-click** → popover.
  **Cmd+,** → Preferences. **Cmd+Q** → quit.

## What doesn't work yet

- **Claude row's `used %` is a time proxy, not real token usage.**
  Until Anthropic persists `rate_limits` to disk (or we shell out to a
  hypothetical `claude usage` CLI command), Claude's row reports
  `elapsed_time_in_session / 5h`, which assumes you've been linearly
  consuming quota proportional to wall-clock time. Real usage can be
  10× lower (idle session) or 10× higher (token-heavy multi-tool messages).
  Treat it as "you're in a Claude session for N minutes", not "you've burned X%".
- **Codex row goes stale for desktop-only users.** cuwatch reads
  `payload.rate_limits` from `~/.codex/sessions/**/*.jsonl`. That file
  is only refreshed when you run `codex` from the CLI. If you use the
  ChatGPT Codex desktop app (or VS Code extension), nothing writes to
  disk — the desktop app fetches its numbers live from a private OpenAI
  API and never caches the response anywhere cuwatch can read. Until
  we (a) reverse-engineer that API and authenticate against it, or
  (b) Codex CLI starts persisting on app-side events too, the row will
  read whatever percentage was true at your last CLI invocation.
- **No signed `.app` bundle**. Only Xcode-dev-build runs.
  `swift run` produces a binary, not an `.app`, which means no codesign,
  no notarize, no Homebrew Cask distribution. **Phase 3.**
- **Claude Full Disk Access**. Required to read `~/.claude/projects/` in a
  sandboxed Mac App Store build. Until the `.app` bundle exists, FDA can't
  be granted persistently — the row shows "Grant Full Disk Access" guidance
  but the system-settings handoff won't stick for dev builds.
- **Codex / Claude session start detection is mtime-based**. The schema of
  Codex session files (`~/.codex/sessions/`) is not yet parsed; we use file
  mtime as a stand-in. Good enough for "is something happening now", not
  precise for cost tracking.
- **No history view, no trend graphs.** v1 is point-in-time only.
- **No notification center alerts at red threshold.** Visual only for now.

## Build

Requirements: **macOS 12+**, **Xcode 16+**, an Apple Developer team for signing
(local dev only — free Apple ID account works).

```bash
git clone https://github.com/xunull/cuwatch
cd cuwatch
# 1. Headless library tests (no Xcode required):
swift test                 # → 177 / 177 passing in ~200ms

# 2. Build and run the macOS app:
open cuwatch/cuwatch.xcodeproj
# In Xcode: select your Team under Signing & Capabilities → ⌘R
```

The status bar app appears in the menu bar within seconds of launch.
**No Dock icon** by design (`.accessory` activation policy).

### Layout

```
cuwatch/
├── Package.swift              ← SwiftPM library + tests (headless)
├── Sources/CuwatchCore/       ← business logic, vendor integrations, state
├── Tests/CuwatchCoreTests/    ← 177 tests
└── cuwatch/                   ← Xcode application target
    ├── cuwatch.xcodeproj
    └── cuwatch/
        ├── AppDelegate.swift  ← NSStatusItem owner + monitor coordinator
        ├── UI/                ← SwiftUI popover + Preferences + Dial view
        └── Assets.xcassets
```

`CuwatchCore` is intentionally headless so CI can run `swift test` in 200ms
without spinning up Xcode. The app target depends on it via local SwiftPM
package reference.

## Configuration

Stored in `UserDefaults` (preferences) and macOS Keychain (Minimax token).

| Knob | Default | Range / Allowed |
|------|---------|-----------------|
| Poll interval | 30s | 10s – 300s (clamped) |
| Main service lock | auto | auto / claude / codex / minimax |
| Minimax endpoint | global (`api.minimaxi.com`) | global / china (`api.minimaxi.cn`) |
| History retention | 30 days | 1 – 90 days |
| Minimax bearer token | none | stored in Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

All of the above editable from the in-popover Preferences panel.

## Architecture

For the deep dive — visual design rationale, state-machine diagrams, motion
language, font choices, threshold ladder reasoning — see [`DESIGN.md`](./DESIGN.md).

Quick model:

```
[Claude Reader]         [Codex Reader]          [Minimax Client]
   reads JSONL              probes ~/.codex/          HTTPS Bearer
        │                       │                          │
        ▼                       ▼                          ▼
[ServiceMonitor]        [ServiceMonitor]          [ServiceMonitor]
  poll loop + backoff     poll loop + backoff       poll loop + backoff
        │                       │                          │
        └───────────────────────┴──────────────────────────┘
                                │
                                ▼
                          [StateStore]
                       (ObservableObject)
                                │
                                ▼
                       [PopoverViewModel]
                 (500ms debounce + 6-state dispatcher)
                                │
                                ▼
                ┌───────────────┴────────────────┐
                ▼                                ▼
         [DialView NSView]                 [SwiftUI popover]
         (menu bar 16x16,                  (340pt wide, slide-in
          CAShapeLayer +                    Preferences panel)
          CASpringAnimation)
```

Each `ServiceMonitor` independently times out, backs off, and recovers — one
vendor going down (Minimax API 500, Anthropic JSONL malformed, codex CLI
uninstalled) does NOT pull the others into a neutral state.

## Tech

- **Swift 5.10** + SwiftUI + AppKit (NSStatusItem)
- **macOS 12+** deployment target (everywhere except `View.tracking()` which
  is macOS 13+ and TODO)
- **No third-party dependencies** in production. URLSession, Foundation, Combine,
  AppKit, SwiftUI, Security only.
- **177 tests** (XCTest), business-logic only — view layer is intentionally
  uncovered per project decision.

## Status & roadmap

This is **v0.0.1**, a working alpha. The author is dogfooding it on a daily
driver. Phase 3 (signing + notarization + Homebrew Cask) is the next ship gate.

| Phase | What | Status |
|-------|------|--------|
| 0 | Spike Codex / Minimax / Claude schemas | done |
| 1 | DESIGN.md, plan, type tokens, color palette | done |
| 2 | Core library + Xcode app + 177 tests | **done (here)** |
| 3 | `.app` bundle, codesign, notarize, GitHub Releases, Homebrew Cask | next |
| 1.1 | Burn-rate ghost-line projection, trend history, notifications | later |

## Contributing

The project is in early-iterate mode — the public API isn't stable, the
design decisions log in `DESIGN.md` is still active, and large PRs may
conflict with in-flight work.

If you find a real bug or want to discuss design directions: file an issue.
Code contributions welcome but please open the issue first.

Project conventions live in [`CLAUDE.md`](./CLAUDE.md). Visual conventions
live in [`DESIGN.md`](./DESIGN.md). Both are authoritative.

## License

TBD. The intent is MIT or Apache-2.0 — to be locked in before the `.app`
release. If you want to fork before that, please reach out first.

## Acknowledgments

The "single dial in the menu bar" anchor and the analog-instrument visual
direction are intentional reactions to the SaaS-template look that dominates
the category. None of the existing menu bar utilities (Stats, ClaudeBar,
SessionWatcher, CodexBar, iStat Menus) provided design inspiration — they
provided the negative space cuwatch is trying to differentiate against.
