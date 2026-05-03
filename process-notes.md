# Process Notes

## /onboard

Cart cycle #14 for Estevan. Returning builder, all decay fields fresh (2026-04-25, well within TTL).

### /onboard — autonomous run

Run mode: **autonomous** (builder opted in at the pacing gate). Skipped the entire interview (steps 3 through 11b) per the SKILL's autonomous-fill strategy. All values either pulled from `~/.claude/profiles/builder.json` or inferred from the design spec at `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`.

**Values surfaced (every assumption recorded, per the autonomous contract):**

| Field | Value | Source |
| --- | --- | --- |
| Name | Estevan | Profile (`shared.name`) |
| Identity | Builder, "Mr. Solo Dolo", 626Labs Fort Worth, 20+ years PC/Windows, vibe coder, ~10 deployed apps, active VC plugin contributor | Profile (`shared.identity`) |
| Technical experience level | experienced | Profile (`shared.technical_experience.level`) |
| Languages on file | TypeScript, Python, JavaScript, Luau, C#, HTML/CSS, C++ | Profile |
| Frameworks on file | React 19, Next.js, Vite, Tailwind, Firebase, FastAPI, Flask, Express, .NET 8/9, Azure, Expo, RN, Drizzle, Playwright, WPF, C++/WinRT, Windows App SDK, MSIX, Ollama | Profile |
| AI agent experience | Deep — 13 prior Cart cycles, ships Claude Code plugins, autonomous build system | Profile |
| Persona | architect | Profile (`shared.preferences.persona`, fresh) |
| Tone | terse and direct | Profile (fresh) |
| Pacing | brisk | Profile (fresh) |
| Communication style | casual, no corporate speak; decisive course corrections; raises real objections directly | Profile (fresh) |
| Creative sensibility | clean, functional, high-contrast; dark themes; ships polish but not at the expense of shipping | Profile (fresh) |
| Mode | builder | Profile (`plugins.vibe-cartographer.mode`) |
| Build mode preference | iterative-prototype | Profile |
| Autonomy level | fully-autonomous | Profile (set 2026-04-26) |
| Project goals | Mac-native macro maker for Roblox; PS99 v1 anchor; community-authored plugins from v2; factory pipeline patches macros within hours of game updates; **no telemetry, ever**; Mac-native posture as the wedge | Spec § TL;DR + § 1 |
| Project origin | Spec-first cycle: bootstrapped from a pre-onboard brainstorm + spec authoring + keystone CLAUDE.md (Substrate (mm) pattern from cycle #13) | Brainstorm session 2026-05-03 + spec doc + CLAUDE.md commits |
| Design direction | 626Labs design system at `~/projects/626labs-design/` (cloned 2026-05-03) + skill at `~/.claude/skills/626labs-design/`. Sanduhr für Claude as SwiftUI precedent. Dark navy + neon cyan/magenta + product-specific teal; Space Grotesk + Inter + JetBrains Mono. | Spec § 8 + 626labs-design repo |
| Prior SDD experience | Deep — 13 prior Cart cycles, active VC plugin contributor | Profile + cycle history |
| Architecture docs | Yes — design spec at `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md` (535 lines, 12 sections); operational guidance in `CLAUDE.md`; design system at `~/projects/626labs-design/` | This repo |
| Deployment target | **github-releases** (signed + notarized DMG via GitHub Releases, Sparkle 2.x EdDSA appcast for auto-update) — *changed from prior cycle's `marcus-landing-zone-azure-devops`; this is a 626Labs project, not a Marcus tenant project* | Spec § 7 |
| Project-specific stack additions (NOT global identity) | Swift / SwiftUI (Mac app), ScreenCaptureKit + CGEventTap + AVFoundation + NSAccessibility (Apple APIs), Sparkle 2.x (auto-update), Bun (factory pipeline later) | Spec — kept project-local; not added to global `shared.technical_experience` per the "don't fabricate" rule |

No `(default — confirm on next run)` tags this run — every value is sourced from profile or spec, none invented from thin air.

**Substrate observation for this cycle:** macRo is the **second spec-first Cart cycle** (Substrate (mm)). First was Sales Standards POC (cycle #13). This one is heavier on the upstream artifacts — full design spec (535 lines) + bootstrapped CLAUDE.md (132 lines) + scaffolded `.claude/agents/` (2 production + 3 stubs) + `.claude/rules/` (3 stubs) + `.claude/hooks/` README — all landed BEFORE /onboard ran. /scope and /prd will likely compress significantly because the spec is dense and validated. Pattern verification: when the upstream brief is more thorough than typical, **trust it more, which means verify it more** (Vibe Thesis cycle #11 lesson). /scope should run an upstream-freshness check against the spec rather than re-deriving the project from scratch.

**Tenant boundary:** This is a 626Labs project, NOT a Marcus tenant project. `mcp__626Labs__*` calls are appropriate when the Dashboard MCP is connected. Currently the Dashboard MCP is **not connected** in the running session — the bind step (`mcp__626Labs__manage_projects findByRepo`) is deferred until the MCP server reconnects. CLAUDE.md describes the eventual state.

**Friction / session logging:** the VC session-logger and friction-logger machinery were not invoked this run (the plugin data dir at `~/.claude/plugins/data/vibe-cartographer/` doesn't yet exist on this machine; bootstrapping it is internal-VC-machinery work that lives outside the scope of /onboard's user-facing flow). Future cycles on this machine will inherit the missing-infra cleanly when those skills run for the first time.
