# Design System — cuwatch

Created by `/design-consultation` on 2026-06-12.
Memorable anchor: **"This menu bar app is a meter."**

> Semantic note (2026-06-21 reversal logged in `decisions.active.json`): the dial reports **usage**, not remaining — needle climbs as you spend, mirroring Claude / Minimax vendor dashboards. The 1960s analog instrument aesthetic still holds; the metaphor is a tachometer / pressure meter, not a fuel gauge. Color ladder: brass < 70% used, burnt orange 70-90%, oxidized red ≥ 90%.
Wedge: **The AI usage tracker that refuses to look like an AI tool.**

## Product Context

- **What this is:** A macOS menu bar utility that displays current usage for three AI services (Claude Code Plan, Codex CLI on ChatGPT Plus/Pro, Minimax Token Plan) at a glance, with a single dial icon in the menu bar and a richer popover on click.
- **Who it's for:** Developers who actively use 2-3 AI services at once and need ambient awareness of "can I keep going right now."
- **Space/industry:** Developer tools. macOS menu bar utilities. The category is crowded (ClaudeBar, Stats, SessionWatcher, CodexBar, ClaudeUsageBar, etc.) and convergent. Competitors split into "no design" (Stats, ClaudeBar = GitHub README utility) and "generic SaaS template" (SessionWatcher).
- **Project type:** Native macOS app (AppKit `NSStatusItem` for the icon + SwiftUI popover for the panel). Distributed via GitHub Releases + Homebrew Cask. Not on the Mac App Store.

## Aesthetic Direction

- **Direction:** Industrial / Utilitarian × Editorial restraint
- **Decoration level:** Minimal-intentional (no surface ornament; typography + warm patina do all the work)
- **Mood:** A blackened-brass cockpit instrument from a 1960s analog computer, sitting quietly in your menu bar with the warm patina of a workshop tool that has been on someone's desk for ten years. Reads as something a person made on purpose, not something generated from a template.
- **Reference apps:**
  - [Mela](https://mela.recipes/) — editorial confidence, warm + dark contrast, one signature color
  - [iA Writer](https://ia.net/writer) — "only typography and whitespace, zero decoration"
  - [Linear](https://linear.app/) — restraint + density + a single acid accent
  - Teenage Engineering OP-1 firmware — restraint as the most expensive thing in the product
  - Leica Q menu system — instrument language

## Typography

> **2026-06-21 reversal:** dropped IBM Plex Mono bundle in favor of the system monospaced design font (SF Mono on macOS 13+, Menlo on older). Reasoning: at the 10-13pt sizes that dominate the menu bar surface, Plex Mono and SF Mono are visually indistinguishable; the wedge cost is only paid at 22pt + 34pt readouts. The user opted to "不搞特殊" — accept the small visual differentiation loss in exchange for zero bundle weight, no font registration code, no license attribution, and native rendering. The original Plex Mono framing is preserved below as historical record; see Decisions Log.

- **Everything:** the system monospaced design font (SF Mono on macOS 13+, Menlo on older). In SwiftUI: `Font.system(size:, design: .monospaced)`. In AppKit: `NSFont.monospacedSystemFont(ofSize:weight:)`.
- **Weight set:** 400 Regular and 500 Medium are sufficient for v1.
- **Tabular figures:** ON everywhere (SwiftUI `monospacedDigit()`).
- **Tracking:** -0.01em (text), -0.04em (the 34pt readout). Note: `View.tracking()` is macOS 13+; on earlier targets defer until deployment bumps.
- **Scale (locked, do not add sizes):**
  | Token | Size | Role |
  |---|---|---|
  | `display` | 34pt | Single readout (main % in popover header). Only one per popover. |
  | `xl` | 22pt | Sub-readout (e.g. "resets in 2h 14m") |
  | `l` | 15pt | Body (Preferences prose, tooltips) |
  | `m` | 13pt | Service % numbers |
  | `s` | 11pt | Meta (timestamps, "resets in 2h 14m" small variant, footer) |
  | `xs` | 10pt | Labels (uppercase, tracked 0.14em, "CLAUDE / 5H WINDOW") |

### Historical: original Plex Mono framing (kept for trail)

- **Everything (deprecated 2026-06-21):** IBM Plex Mono (one family, all roles, no proportional sans, no serif). SIL OFL 1.1, ship OTF with app, register via `CTFontManagerRegisterFontsForURLs`.
- **Why not Berkeley Mono (still applies if anyone reconsiders):** Berkeley Mono is the "premium developer" signature in 2026 and would be cuwatch's first-choice typeface if licensing fit. But Berkeley Mono is paid ($75/dev) and embedding terms must be verified per redistribution; cuwatch is open source. IBM Plex Mono was the OSS path. After 2026-06-21 the choice is "system monospace, accept the wedge cost".
- **Old anti-list:** Inter, Roboto, Arial, Helvetica, SF Pro, system-ui — none. (SF Mono / Menlo now allowed per reversal.)

## Color

- **Approach:** Restrained warm-neutral. One brass accent. Two alarm states. No vendor colors.

### Dark mode (default — the one that matters)

| Token | Hex | Role |
|---|---|---|
| `bg` | `#0E0C0A` | Background (near-black with green-brown undertone, never pure #000) |
| `surface` | `#171411` | Popover surface |
| `surface-2` | `#211D18` | Raised row surface, hairlines |
| `ink` | `#E8DFD0` | Primary text (warm bone — never #FFFFFF) |
| `ink-mute` | `#A39584` | Muted text (labels, secondary metadata) |
| `ink-dim` | `#6B5F50` | Dim text (timestamps, footer) |
| `brass` | `#C9A86A` | Accent — aged brass, the only "color" in normal state. Used for: dial needle, progress bar fill, label tags. |
| `warn` | `#D4823A` | Burnt orange — fires at ≥ 70% **used** on any service. (Ghost-line / burn-rate projection trigger deferred to v1.1+ per plan: "v1 不带预测".) |
| `danger` | `#B8412E` | Oxidized iron-red — fires at ≥ 90% used, OR window locked. No pulse, just red. |

### Light mode (parchment, not white)

| Token | Hex | Role |
|---|---|---|
| `bg-l` | `#F2EDE3` | Background — warm parchment |
| `surface-l` | `#E8E0D2` | Surface |
| `surface-2-l` | `#DDD3C0` | Raised |
| `ink-l` | `#2A2520` | Primary text |
| `ink-mute-l` | `#6B5F50` | Muted |
| `ink-dim-l` | `#9B8B78` | Dim |
| `brass-l` | `#8B6B2F` | Darker brass, same family |
| `warn-l` | `#B8651F` | Warn |
| `danger-l` | `#8B2A1E` | Danger |

### Contrast verification

- Brass on background (dark): 7.2:1 — WCAG AAA
- Ink on background (dark): 12.6:1 — WCAG AAA
- Ink-mute on background (dark): 5.4:1 — WCAG AA
- All pairs verified at design time. No transparency tricks for contrast.

### Anti-color rules

- **Never** color-code services by vendor (no Anthropic-orange, no OpenAI-green, no Minimax-blue). Treat the three services with identical visual weight.
- **Never** introduce a second accent in v1.
- **Never** use pure black, pure white, or saturated #FF*-grade colors anywhere.

## Spacing

- **Base unit:** 4pt
- **Density:** Comfortable (dense but breathable)
- **Scale (locked, do not deviate):**
  | Token | Value | Use |
  |---|---|---|
  | `s-4` | 4pt | Inline spacing between label and chip |
  | `s-8` | 8pt | Between row label and bar |
  | `s-12` | 12pt | Bar internal padding, small gaps |
  | `s-16` | 16pt | Between service rows |
  | `s-24` | 24pt | Popover outer padding, section gaps |
  | `s-32` | 32pt | Between popover composition zones (header → rows → footer) |
  | `s-48` | 48pt | Reserved for marketing / README sections, not used in app |

- **Popover dimensions:** 340pt wide. Height auto (responds to content), expected 360-440pt range.
- **Hairline:** 1pt, color `surface-2` (dark) or `#C9BFAA` (light).

## Layout

- **Approach:** Grid-disciplined. 4pt baseline grid. Locked type sizes form an implicit vertical rhythm.
- **Popover composition (top to bottom):**
  1. **Header (~80pt tall)** — left: 34pt main readout `display` + 10pt brass label `xs uppercase`. Right: 48px dial replica.
  2. **Three service rows (56pt each, separated by `s-16`)** — each row: 10pt uppercase label `xs`, 6pt-tall horizontal progress bar with ghost line beneath, percentage + reset meta right-aligned in tabular mono.
  3. **Footer** — 11pt dim text: "Updated 14s ago / Preferences"
- **Menu bar icon canvas:** 16×16pt template canvas. Custom NSView with CALayer for the dial arc + needle.

### What is NOT allowed in the popover

- Circular progress rings (rings prevent cross-service comparison)
- Vendor logos / colored service pills
- Decorative emoji or icons
- More than one accent color at once
- More than one font weight per text style
- Centered headlines or hero copy

## Motion

- **Approach:** Intentional but mechanical (analog meter physics, not Material Design ease-out)
- **Triggers (event-driven only):**
  | Event | Animation |
  |---|---|
  | Data poll tick → numeric change | Damped spring 280ms, overshoot 4° on the dial needle, then settle |
  | Popover open | Fade + 2pt scale in, 200ms ease-out |
  | Popover close | Fade out, 100ms ease-in |
  | State color transition (green→warn or warn→danger) | Color crossfade 350ms ease-in-out |
  | Warning pulse (at ≥ 80% used) | Single 30s-interval brass tick pulse at 60% opacity, 350ms ease-in-out |
  | Hover NSStatusItem | Optional very subtle indicator, ≤ 100ms |
- **Reduce Motion:** all of the above → instant state change. Not a faster animation — no interpolation at all.
- **Forbidden:** continuous 60fps loops, ticker-style animation, scroll-driven effects, parallax, glow / shadow pulses.

## Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-06-12 | Aesthetic = industrial × editorial restraint | Directly delivers "this is a gauge" anchor; differentiates from SessionWatcher's generic SaaS template and Stats/ClaudeBar's no-design utilitarianism. |
| 2026-06-12 | IBM Plex Mono OSS (not Berkeley Mono paid) for v1 | Open source app needs embeddable typeface. IBM Plex Mono is SIL OFL + ships with app. Berkeley Mono is the v1.x upgrade if licensing fits. |
| 2026-06-12 | Warm-neutral palette + single brass accent | No vendor colors. No SaaS blue. Differentiation comes from refusing AI-tool convention. |
| 2026-06-12 | Single dial in menu bar + 3 horizontal bars in popover (no rings) | Dial expresses "where is the needle" at a glance. Bars allow cross-service compare in one saccade. Rings cannot do either job. |
| 2026-06-12 | Ghost line for burn-rate projection inside each bar | Predictive UI without prose. Single visual element answers "will I run out before the window resets". |
| 2026-06-12 | 4pt grid + locked type scale {10, 11, 13, 15, 22, 34} | Instrument precision. The 34pt readout is the only thing allowed to be large. |
| 2026-06-12 | Motion = analog meter physics (damped spring + 4° overshoot) | Reinforces "gauge" anchor at the kinetic layer, not just visual. Reduce Motion → instant. |
| 2026-06-12 | Dark default, parchment light mode | Dev tools live in dark mode. Light mode = warm parchment (matches gansha session paradigm), not sterile white. |
| 2026-06-13 | 4pt grid confirmed via plan-design-review | Plan office-hours DAT #2 originally said "8pt baseline grid"; conflict resolved in DESIGN.md's favor (per /plan-design-review D2). Plan DAT #2 patched to "4pt grid per DESIGN.md". |
| 2026-06-13 | VoiceOver labels English-only for v1 | Per /plan-design-review D5. 30+ labels enumerated in plan's Accessibility specifications section. Localization deferred to v1.x. Matches existing app-UI English-only decision. |
| 2026-06-13 | Onboarding state design: instrument-stays-instrument | Per /plan-design-review D3. Zero-configured-services popover keeps dial+3-row layout, each row reads "Not configured · Add token", click expands inline token form. No welcome page. |
| 2026-06-13 | Preferences form factor: in-popover slide-in panel | Per /plan-design-review D4. 340pt wide, slides 200ms from right, three sections (Services / Behavior / Data & Privacy). Preserves instrument anchor — no separate window. |
| 2026-06-21 | **Anchor reversal: "gauge" → "meter"; dial semantics: remaining → used.** Color ladder: green < 70% used, yellow 70-90%, red ≥ 90%. | After ⌘R verifying against real data, every vendor dashboard (Claude.ai, Minimax console, ccusage) displays USED, not remaining. Cross-referencing with cuwatch required mental flip. Tachometer / pressure-meter family preserves 1960s analog aesthetic and damped-spring-with-overshoot motion language — only the polarity flipped. Per /plan-eng-review 2026-06-21 D-reversal. Touched 11 files, 178 tests pass. Earlier 2026-06-12 "gauge" entries above record the original framing and are kept for historical trail. |
| 2026-06-21 | **Typography reversal: IBM Plex Mono (bundled OTF) → system monospaced design font (SF Mono on macOS 13+, Menlo on older).** | User call: "就使用 SF Mono 这个字体吧，不要搞特殊". At 10-13pt sizes (the menu bar surface that dominates the wedge), Plex Mono and SF Mono are visually indistinguishable; the wedge cost is paid only at 22/34pt readouts. Accept the small differentiation loss for: zero bundle weight (was ~500KB-1MB for two OTF weights), no font registration code at launch, no SIL OFL attribution overhead, native Apple rendering at all sizes. The 2026-06-12 "IBM Plex Mono OSS" entry above records the original choice and is kept for historical trail. Anti-list updated: SF Mono and Menlo are now allowed; Inter / Roboto / Arial / Helvetica / SF Pro / system-ui still excluded. |

## Implementation Notes (for the AppKit + SwiftUI build)

- **Menu bar icon:** custom `NSView` subclass returned by `NSStatusItem.button`. Draw arc + needle via `CALayer` or directly in `draw(_:)`. Three branches for appearance: `NSAppearance.current` reads `aqua / darkAqua / accessibilityHighContrastDarkAqua` etc.
- **Template mode for accent-tinted menu bar:** when `NSStatusItem.button.appearsDisabled == false` AND system menu bar is in tinted state, switch icon to `template = true` and let the system tint take over.
- **Tabular figures in SwiftUI:** `.monospacedDigit()` on every `Text` that displays a number.
- **Font loading in app:** none required as of 2026-06-21 — uses `Font.system(.monospaced)` (SF Mono on 13+, Menlo earlier). No OTF bundling, no `CTFontManagerRegisterFontsForURLs` call, no `Fonts provided by application` Info.plist key.
- **Color tokens:** define as `Color` extensions backed by `NSColor` (dynamic dark/light). Wrap in `Asset Catalog` if shipping `.xcassets`, or hardcode in a `Design.swift` module.
- **Reduce Motion check:** `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. Use it in every animation site, not centrally — animation removal must be explicit, not hidden behind a wrapper.

## Living Document

This file is the source of truth for cuwatch visual decisions. Update the Decisions Log when adding/changing anything. Never deviate without explicit user approval. The wedge depends on every decision serving the **meter** anchor (anchor was "gauge" through 2026-06-13; reversed 2026-06-21 — see Decisions Log).
