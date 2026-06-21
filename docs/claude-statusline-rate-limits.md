# Reading Claude Code rate_limits via the official statusline channel

> Technical research doc — not an implementation spec. This captures everything we
> know about Anthropic's documented `rate_limits` exposure so we can decide
> whether to build against it without re-doing the spike.
>
> Spike date: 2026-06-21
> Author / reviewer: cuwatch maintainers
> Status: **proposed** — see `cuwatch-integration.md` (when written) for the actual build plan

## TL;DR

Anthropic exposes Claude.ai (Pro/Max) `rate_limits.five_hour.used_percentage` and
`rate_limits.seven_day.used_percentage` **as part of the JSON piped to a
statusline script's stdin**, starting in Claude Code v1.2.80. This is a
documented, vendor-supported channel. The data is the same one Claude.ai's web
UI shows — not an approximation.

The challenge is timing: Claude Code only runs the statusline script while
**Claude Code itself is running and rendering**. To make cuwatch (an outside
menu bar app) see this data, we have to bridge it: Claude Code → statusline
script → JSON file on disk → cuwatch poller.

This doc covers what's documented, what we verified, the edge cases, and the
two integration patterns we should consider before writing any code.

## Why this matters

cuwatch v0.0.1 ships a `Claude` row in the popover that displays
`elapsed_in_session / 5h` as a percentage. This is a **time proxy**, not real
token usage. It diverges from actual usage by 10× either way depending on
whether the user is idle or fires token-heavy multi-tool messages.

Competing tools (ccusage, claude-usage-tracker, phuryn/claude-usage) parse
`~/.claude/projects/*.jsonl` and **sum per-message `usage.input_tokens` etc.**,
then divide by a **hardcoded plan limit** (e.g. Max20 = 220K tokens / 5h). This
is closer to real usage but still:

- breaks when Anthropic changes plan limits (Pro's quota was bumped twice in
  the past year)
- requires the user to tell the tool their plan tier
- doesn't match Anthropic's actual server-side calculation (caching credits,
  reasoning tokens, weekly-vs-5h interaction)

The statusline approach **bypasses all of this**: Anthropic computes the
percentage on their server and hands it to us cooked. If we can read it
reliably, cuwatch's Claude row becomes more accurate than ccusage's by
construction.

## The mechanism (from Anthropic's official docs)

Reference: <https://code.claude.com/docs/en/statusline>

### Registration

Statusline scripts are registered in `~/.claude/settings.json` (user-level) or
in a project-level `.claude/settings.json`. Schema:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/cuwatch-statusline.sh",
    "padding": 2,
    "refreshInterval": null,
    "hideVimModeIndicator": false
  }
}
```

| Field | Required | What it does |
|---|---|---|
| `type` | yes | Must be `"command"` |
| `command` | yes | Path to a shell script OR an inline shell command. Runs in a shell, so `jq …` works inline |
| `padding` | no, default 0 | Extra horizontal padding (characters) for the rendered statusline |
| `refreshInterval` | no, default unset | Seconds. If set (min 1), re-runs the command on a timer **in addition to** event-driven updates. Useful for time-based or external data (clock, slow git state). |
| `hideVimModeIndicator` | no, default false | Suppress the built-in `-- INSERT --` if your script renders `vim.mode` itself |

Users can also run `/statusline <natural language description>` inside Claude
Code and it'll write the script + update `settings.json` automatically. Useful
for `/statusline delete` to disable.

### When the script runs

Per the docs (`How status lines work` section):

> Your script runs after each new assistant message, after `/compact` finishes,
> when the permission mode changes, or when vim mode toggles. Updates are
> debounced at 300ms, meaning rapid changes batch together and your script
> runs once things settle. If a new update triggers while your script is still
> running, the in-flight execution is cancelled.

So the firing rule:

```
       ┌────────────────────┐
       │  Claude Code event │
       │  (assistant msg /  │
       │  /compact / perm   │
       │  mode / vim mode)  │
       └─────────┬──────────┘
                 ▼
       ┌────────────────────┐
       │  Debounce 300ms    │
       └─────────┬──────────┘
                 ▼
       ┌────────────────────┐
       │  Spawn script;     │
       │  pipe JSON → stdin │
       │  capture stdout    │
       └────────────────────┘
```

Implication for cuwatch:
- **During an active Claude Code session**, the script fires after every
  assistant turn — i.e. real-time enough that "freshness within a few seconds"
  is guaranteed
- **While Claude Code is idle** (user not interacting, no API calls), the
  script doesn't fire — the persisted JSON file stays stale until next message
- **Background subagents** don't trigger the main statusline; coordinator
  sessions waiting on subagents go quiet too. Anthropic's workaround: set
  `refreshInterval` to also poll on a timer. **For cuwatch, setting
  `refreshInterval: 5` (or so) is a hard requirement** — otherwise we miss
  whatever the user did with a background agent

### Stdin contract

Claude Code pipes a JSON object to the script's stdin every time it runs.
Relevant fields for rate_limits work (full schema in the Anthropic docs):

```json
{
  "model": {
    "id": "claude-opus-4-7",
    "display_name": "Opus 4.7"
  },
  "session_id": "ses_…",
  "session_name": "feature-foo",
  "transcript_path": "/Users/.../session-12345.jsonl",
  "version": "1.2.80",
  "workspace": {
    "current_dir": "/path/to/project"
  },
  "context_window": {
    "current_usage": 47831,
    "max": 200000,
    "used_percentage": 23.9,
    "remaining_percentage": 76.1
  },
  "rate_limits": {
    "five_hour": {
      "used_percentage": 23.5,
      "resets_at": 1738425600
    },
    "seven_day": {
      "used_percentage": 41.2,
      "resets_at": 1738857600
    }
  },
  "vim": { "mode": "NORMAL" },
  "agent": { "name": "security-reviewer" },
  "pr": { "number": 1234, "url": "...", "review_state": "pending" },
  "worktree": { "name": "my-feature", "path": "...", "branch": "..." }
}
```

The fields we care about:

| Path | Type | Meaning |
|---|---|---|
| `rate_limits.five_hour.used_percentage` | number 0-100 | What % of the 5h window's budget you've burned |
| `rate_limits.five_hour.resets_at` | int (Unix epoch seconds) | When the 5h window resets |
| `rate_limits.seven_day.used_percentage` | number 0-100 | What % of the 7d (weekly) window's budget you've burned |
| `rate_limits.seven_day.resets_at` | int (Unix epoch seconds) | When the 7d window resets |
| `session_id` | string | Stable per Claude Code session, unique across sessions. **Use this as a cache discriminator**, NOT process ID (the script is spawned fresh each invocation, so `$$` / `os.getpid()` are useless) |

### Absent / null cases (must handle)

Per the docs, **all** of these are realistic in production:

- **`rate_limits` itself absent**: only appears for Claude.ai Pro/Max subscribers.
  Free tier / API key users will never see it. Our consumer must treat the
  whole object as optional.
- **`rate_limits` absent until first API response**: even for Pro/Max users,
  the field doesn't show up until after the first assistant turn of the
  session. New session = no data yet.
- **`five_hour` or `seven_day` independently absent**: docs say "each window
  may be independently absent." Be defensive in JSON access.
- **`context_window.current_usage` null**: `null` before first API call, and
  again after `/compact` until the next API call. Not strictly our concern
  but signals that early-session state is genuinely incomplete.

### Output environment quirks

- `COLUMNS` and `LINES` env vars are set to terminal dimensions. `tput cols`
  does NOT work (Claude captures output, isn't connected to terminal). Not
  relevant for cuwatch since we don't render to terminal — but worth knowing.
- Script's stdout is the rendered statusline content (newlines = multiple
  rows). Stderr is captured for `claude --debug` logging.
- Hooks integration: if `disableAllHooks: true` is in settings, statusline
  is also disabled. Need to validate this isn't set during cuwatch
  installation.

## Verified facts about our specific environment

I checked the user's actual `~/.claude/` install (2026-06-21):

| Check | Result |
|---|---|
| Does `~/.claude/projects/*.jsonl` contain `rate_limits`? | **No.** Greps that look like hits are actually our own conversation transcripts logging the term as discussion text. |
| Does `~/.claude/transcripts/*.jsonl` contain `rate_limits`? | **No.** Same situation — only the literal term as discussion content. |
| Does `~/.claude/` have any persisted `rate_limits` blob? | **No.** Confirmed via recursive grep. |
| Is the `statusLine` field in user's current `settings.json`? | (verify before integration — assume not for new users) |
| Does Anthropic's documented JSON match what's actually delivered? | Not yet verified live — needs a synthetic statusline script that just dumps stdin to a file, then run a Claude Code interaction and inspect the file. **This is the first thing to do in the integration spike.** |

The bottom line: **The statusline JSON is the only on-disk source of true `rate_limits` for Claude Code.** It does not exist anywhere else on the user's machine. If we don't read it, we cannot show real Claude usage.

## How cuwatch should bridge this

The basic loop:

```
   ┌─────────────────────┐
   │  Claude Code        │
   │  (running session)  │
   └──────────┬──────────┘
              │ pipes JSON stdin
              ▼
   ┌─────────────────────┐
   │  cuwatch-statusline.│
   │  sh                 │
   │                     │
   │  1. read stdin      │
   │  2. extract         │
   │     rate_limits +   │
   │     context_window  │
   │  3. write JSON to   │
   │     known path      │
   │  4. echo passthrough│
   │     to stdout       │
   └──────────┬──────────┘
              │ writes file
              ▼
   ┌─────────────────────┐
   │ ~/.claude/cuwatch-  │
   │ rate-limits.json    │
   └──────────┬──────────┘
              │ poll
              ▼
   ┌─────────────────────┐
   │  cuwatch.app        │
   │  ClaudeReader       │
   └─────────────────────┘
```

The statusline script needs to do two things at once:
1. **Persist** the relevant fields to disk so cuwatch can read them
2. **Render** something usable to stdout so the user still gets a useful
   statusline display (we can't just hijack the channel)

### Pattern A — minimal extractor, lets user keep their existing statusline

If the user already has a `statusLine` configured, we can't just overwrite it.
Two sub-options:

- **A.1**: Write a wrapper script that calls their existing script AND our
  extractor. Requires us to know their existing command path. Brittle.
- **A.2**: Don't touch their statusline. Tell them "you need to add this line
  to your existing script" and provide a snippet:
  ```bash
  jq -c '{rate_limits, context_window, session_id, ts: (now|floor)}' \
    > "$HOME/.claude/cuwatch-rate-limits.json" <<< "$INPUT"
  ```
  Manual but transparent.

### Pattern B — owned statusline, but UI-passthrough for existing config

cuwatch writes its own statusline script that:
1. Reads stdin
2. Extracts + persists rate_limits to file
3. Reads the user's "preferred statusline output" from a separate setting
   (defaults to a reasonable cuwatch-branded display, e.g.
   `[Opus 4.7] | 5h: 23% | 7d: 41%`)
4. Prints that to stdout

Then cuwatch's onboarding flow:
- Detect existing `statusLine` in `settings.json`
- If absent: write our config, done
- If present: ask user "we want to install cuwatch's statusline; want to:
  (a) replace yours (we'll show your old config as a comment in the new
  script), (b) wrap yours (call your script first, then ours), or (c) skip
  and you'll add the snippet manually?"

### Pattern C — separate file, not statusline at all (rejected)

What about using a hook (`Stop`, `UserPromptSubmit`, `AssistantTurn` etc.)
instead of statusline? Hooks ALSO receive JSON on stdin, are more flexible
about firing, and some always-run regardless of plan.

**Rejected because**: hooks do NOT receive `rate_limits` in their stdin JSON.
Only the statusline JSON contract includes that field, per the documented
schema. We'd be guessing again — exactly the failure mode we're trying to
avoid.

### Recommended pattern: B with non-destructive default

The integration plan should be **Pattern B with detection-and-merge**:

1. If `statusLine` field absent → write cuwatch config, done
2. If `statusLine` field present → ask user, with default = "wrap"
3. Write the script to `~/.claude/cuwatch-statusline.sh` regardless
4. Inside the script:
   - First line: pass-through to user's old script (if wrap mode)
   - Read JSON from stdin (use `tee` or buffer once)
   - Extract `rate_limits` + `context_window` + `session_id` + epoch timestamp
   - Atomically write to `~/.claude/cuwatch-rate-limits.json` (write to
     `.tmp`, fsync, rename)
   - Print cuwatch's preferred rendering to stdout (so user gets a useful
     display)

## Edge cases & failure modes

### When `rate_limits` is genuinely missing

- New Claude Code session, no API call yet → file has `null` for rate_limits
- Free tier / API key user (not Claude.ai subscriber) → file always has
  `null` rate_limits
- Anthropic's server has an outage and stops sending the field for a while
  → file stays at last seen value (stale)

cuwatch must distinguish these states clearly in its UI:
- "Configure Claude Code statusline" — no file yet
- "Not a Claude.ai Pro/Max subscriber" — file exists but rate_limits never
  populated
- "Claude session active, awaiting first API response" — file shows session_id
  but rate_limits null
- Real `used_percentage` — happy path

### Staleness

The JSON file's last-write timestamp tells us how recently Claude Code
rendered its statusline. We should:
- Include a `ts` (epoch seconds) field in what we write
- Have cuwatch show a "Updated 3m ago" sub-label on the Claude row
- After ~1h of no updates AND we expected one (rough heuristic: user opened
  cuwatch within 5m, suggesting they're awake / working), show a "Claude
  Code not running" indicator

### Concurrent sessions

If the user has multiple Claude Code sessions open simultaneously (e.g. in
different terminals / worktrees), each session runs its OWN statusline script.
All write to the same `~/.claude/cuwatch-rate-limits.json`. The file becomes
"whichever session wrote most recently."

This is **fine for rate_limits** (account-level data, same across all
sessions), but messy for `session_id` / `context_window` (per-session, would
flicker). Solutions:
- Keep `rate_limits` as a top-level field (no session attribution)
- Keep `per_session: { <session_id>: { context_window, last_seen } }` as a
  rolling dict, truncated to last 10 sessions

### Atomic writes

Standard pattern (we already use this in cuwatch's HistoryStore):

```bash
TMP="$HOME/.claude/cuwatch-rate-limits.json.tmp"
DEST="$HOME/.claude/cuwatch-rate-limits.json"
jq -c '...' > "$TMP" <<< "$INPUT"
sync   # not strictly necessary on macOS APFS but cheap
mv "$TMP" "$DEST"  # atomic rename on same FS
```

This avoids cuwatch reading a half-written file mid-update.

### Permission / sandbox concerns

cuwatch installs the statusline script and modifies user's `settings.json`.
This requires:
- File system access to `~/.claude/` (cuwatch already needs FDA for the
  JSONL parsing path — same scope)
- A "we just edited your Claude Code settings, here's a diff" confirmation
  step during onboarding (good UX hygiene)
- A way to uninstall: revert `settings.json`, remove script. Should be a
  one-click action in cuwatch Preferences.

### What if Claude Code's schema changes

Anthropic could:
- Rename `rate_limits.five_hour` → `rate_limits.five_hours` (silly but
  possible)
- Add new windows (`one_day`, `month`)
- Remove the field entirely (unlikely but)
- Change `used_percentage` units (0-100 → 0-1)

Defenses:
- Defensive JSON access (already in the example scripts; `// empty` in jq
  treats absence as success)
- Validate value ranges: `used_percentage` between 0 and 100 inclusive,
  reject otherwise (might mean schema changed)
- Log to a file when schema-unexpected values surface so we can detect
  drift

## Comparison: statusline vs token-sum (ccusage approach)

| Aspect | statusline (this doc) | token-sum (ccusage) |
|---|---|---|
| Source of truth | Anthropic server (real) | Local JSONL token counts |
| Accuracy | Identical to Claude.ai dashboard | Approximate, depends on hardcoded plan limit |
| Plan limit needed | No (server already factored it in) | Yes (Pro / Max / Max20 etc., user must specify) |
| Cache token handling | Built into Anthropic's computation | Tool must implement (read vs creation vs uncached) |
| Weekly limit visibility | Yes (`seven_day.used_percentage`) | Must track separately |
| Updates when Claude Code not running | No (stale until next session) | No (no new JSONL events to sum) |
| User setup needed | Yes (install statusline script) | No (works on existing JSONL) |
| Breaks if vendor changes | Possible (schema changes) | Possible (plan limits change) |
| Differentiation vs ccusage | **Real numbers** | Approximation |

The statusline path **wins on accuracy** but **loses on zero-config UX**.
For cuwatch's wedge (a designed-on-purpose menu bar app), the accuracy win is
worth the one-time setup cost.

## What to validate in the integration spike

Before implementation, **the first hour of build time** should verify:

1. Write a debug statusline script that just dumps stdin to a file
2. Configure it in `~/.claude/settings.json`
3. Run a Claude Code session, send one assistant-bound message, verify
   the dumped JSON contains `rate_limits` for THIS user (Pro/Max subscriber?)
4. Check what the actual schema looks like vs Anthropic's documentation —
   confirm `five_hour` (not `5_hour` or `5h`), confirm exact key paths
5. Verify the `resets_at` timestamps make sense (some future epoch second)
6. Verify behavior with `/compact` — does rate_limits stay or vanish?
7. Verify behavior across multiple windows (open two terminals, see if both
   write to disk reasonably)
8. Verify uninstall: `/statusline delete` and confirm the script is no
   longer running

If ANY of these fail or surprise us, we redo the design before committing to
implementation. **No more shipping based on assumed schemas.**

## References

- Anthropic official docs: <https://code.claude.com/docs/en/statusline>
- Open GitHub feature request for built-in `claude usage` (consolidates 10+
  related issues): <https://github.com/anthropics/claude-code/issues/33978>
- ccusage (reference for the token-sum approach):
  <https://github.com/ryoppippi/ccusage>
- claude-usage-tracker (rate-limit-aware variant):
  <https://github.com/haasonsaas/claude-usage-tracker>
- phuryn/claude-usage (Pro/Max progress bar example):
  <https://github.com/phuryn/claude-usage>
- Statusline known issue: rate_limits.five_hour.used_percentage epoch
  timestamp bug (Anthropic issue #52326):
  <https://github.com/anthropics/claude-code/issues/52326> — worth tracking,
  may affect our defensive parsing

## Open questions for the integration plan (NOT decided here)

1. Do we ship cuwatch's statusline output (the visible text) as
   minimalist (`5h: 23%`) or branded (`[cuwatch] 5h: 23% • 7d: 41%`)?
2. Default `refreshInterval` value: 5s feels right, but verify it doesn't
   spam unnecessarily. Anthropic minimum is 1s.
3. Should cuwatch also expose `seven_day.used_percentage` in the popover, or
   only `five_hour`? (The weekly window is the new constraint Anthropic added
   in August 2025; users may hit it first on heavy weeks.)
4. Wrap-mode UX: how does cuwatch detect the user's existing script's path
   safely? (settings.json is JSON-with-comments in Claude's case, jq-friendly
   but careful)
5. Subagent behavior: do subagent invocations trigger the statusline? Docs
   suggest no — they go quiet — making `refreshInterval` critical.
6. Should we use a hook in addition to statusline for early signal capture
   (statusline only fires after first API response; hooks like
   `UserPromptSubmit` fire on user input)? Hooks don't have `rate_limits`,
   but they could write a "session active" signal earlier.

Decide these in the actual integration spec; not in scope for this doc.
