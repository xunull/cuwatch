# cuwatch — Coding Agent Guide

## Project

cuwatch is a macOS menu bar utility that aggregates current AI service usage (Claude Code Plan, Codex CLI on ChatGPT Plus/Pro, Minimax Token Plan) and displays it as a single dial in the menu bar with a richer popover on click.

Wedge: **The AI usage tracker that refuses to look like an AI tool.** Memorable anchor: **"This menu bar app is a gauge."**

- Platform: macOS 12+
- Stack: AppKit `NSStatusItem` + custom `NSView` for the icon, SwiftUI for the popover content
- License: Open source (MIT/Apache-2.0, TBD)
- Distribution: GitHub Releases + Homebrew Cask. Not on Mac App Store.

## Design System

**Always read `DESIGN.md` before making any visual or UI decision.**

All font choices, colors, spacing, motion, and aesthetic direction are defined there. Do not deviate from `DESIGN.md` without explicit user approval. In QA mode, flag any code that doesn't match `DESIGN.md`.

Key invariants (any change requires explicit approval):
- Typography: IBM Plex Mono everywhere. No Inter, no SF Pro, no system fonts.
- Color: warm-neutral palette + single brass accent `#C9A86A`. No vendor color coding.
- Layout: 4pt grid, locked type scale {10, 11, 13, 15, 22, 34}. No new sizes added casually.
- Motion: event-driven only, never continuous. Respect Reduce Motion (instant transitions, no interpolation).

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

- Product ideas / brainstorming → `/office-hours`
- Strategy / scope → `/plan-ceo-review`
- Architecture → `/plan-eng-review`
- Design system / plan review → `/design-consultation` or `/plan-design-review`
- Full review pipeline → `/autoplan`
- Bugs / errors → `/investigate`
- QA / testing site behavior → `/qa` or `/qa-only`
- Code review / diff check → `/review`
- Visual polish → `/design-review`
- Ship / deploy / PR → `/ship` or `/land-and-deploy`
- Save progress → `/context-save`
- Resume context → `/context-restore`
- Author a backlog-ready spec/issue → `/spec`
