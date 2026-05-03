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

## /scope

Run mode: **autonomous** (`autonomy_level: fully-autonomous` honored from the unified profile + the explicit opt-in at /onboard's pacing gate carried forward). The /scope SKILL doesn't have an explicit autonomous-mode branch like /onboard's, but the (mm) Spec-first cycle pattern from cycle #13 is documented and validated: when the spec is dense and validated, /scope compresses to a pointer-stub.

**Idea evolution:** none in this run. The idea was already fully formed via the upstream brainstorm + spec authoring + keystone work. /scope's job here was to produce the canonical scope artifact in the shape downstream commands expect, not to re-discover the project.

**Pushback / steering:** none in this run (autonomous flow). Real pushback during the brainstorm produced the design unlocks (Este flagged player movement → got its own MOVE lane in v2 mockup; flagged "accuracy-first not speed" → reframed factory promise; flagged community-authored game plugins → plugin loader gets URL-installable from day one). Those are recorded in the spec, not here.

**References that resonated:** Psycho Hatcher's full Modes/ catalog (auto-fuse-pets added as 5th seed; multi-instance + webhook + market-sniping named in out-of-scope). iMovie/FCP visual reference for the editor metaphor.

**Deepening rounds:** zero. Confirmed pattern from `plugins.vibe-cartographer.deepening_round_habits`: zero deepening rounds when vision is formed (8 of 9 prior cycles). The spec is the deepening rounds, retroactively.

**Active shaping:** drove the direction in upstream brainstorm; autonomous in /scope itself per the contract.

**Substrate observation:** This is the **second** cycle running the Spec-first (mm) pattern (first was Sales Standards POC, cycle #13). Cycle #13 produced a 20-line pointer-stub scope.md; this one is denser (~120 lines) because the upstream spec has more architectural surface area (three subsystems, plugin model, factory pipeline) that the scope artifact needs to reflect for downstream /prd discipline. **Pattern refinement:** spec-first scope-stub size scales with subsystem count, not arbitrary line targets.

**Friction / session logging:** still not invoked (same reason as /onboard — internal VC infra).

## /prd

Run mode: **autonomous** (carrying forward the `autonomy_level: fully-autonomous` opt-in).

**What changed vs scope.md:** scope was the project-shape pointer-stub; PRD is the user-stories + ACs + prioritization layer. Per the SKILL: "The PRD should feel significantly more substantial than the scope doc." This one does — six epics (Onboarding, Recording, Editing, Playback, Library, Distribution) × ~5 stories each × 3-5 acceptance criteria = the v1 build's full behavior surface.

**No deepening rounds** — confirmed pattern (8 of 9 prior cycles). The spec already did the brain-dump and the deepening; PRD's job here was structural conversion to the stories+ACs format that downstream commands expect.

**Surprising "what if" questions surfaced:**
- Cuts inside existing gate events — surfaced as an explicit "must remove gate first" UX rule.
- HUD overlapping the Roblox window — explicit rule that HUD-position clicks NEVER appear in the recorded input log; HUD remembers position across sessions.
- Manually-edited factory-patchable macros — explicit "your local edits will be overwritten — keep yours, install update, or save yours as a new macro?" prompt.
- Daylight-savings transitions mid-run — explicit timezone interpretation per manifest.
- Engine asserting `NSWorkspace.frontmostApplication` is Roblox before EVERY synthesis call (not just on entry).
- Reference image generated at different resolution than playback — explicit warning + scaling.

These are the kind of edge cases the SKILL flags as the "PRD is where depth happens" payoff.

**Scope guard:** every "what we'd add with more time" entry is from spec § 11 + new ones surfaced during PRD authoring. Nothing snuck into v1 that wasn't already implied.

**Active shaping:** autonomous flow per the contract; substantive shaping happened upstream during brainstorm + spec.

**One open question flagged as needing answer before /build:** the clan-battle seed macro requires Estevan to brief the agent on PS99 clan-battle mechanics. Tracked in PRD § Open Questions; should land as a /build-time clarification rather than a /spec-time blocker.

**Length check:** PRD is ~300+ lines vs scope's ~120 — meets the SKILL's "significantly more substantial" expectation. Pattern: PRD-to-scope length ratio scales with subsystem count + behavior surface (six epics worth of behaviors > a single subsystem's pointer-stub).

**Friction / session logging:** still not invoked (same reason as prior commands).

## /spec

Run mode: **autonomous** (carrying forward).

**Stack decisions:** all carried from the design spec. Swift 5.9+ / SwiftUI / native Apple APIs only (ScreenCaptureKit, Quartz Event Services, AVFoundation, NSAccessibility); Sparkle 2.x for auto-update; Bun for the factory pipeline (Subsystem B, later cycle); schema codegen via TBD-tool from `schema/macro.schema.yaml`. No surprises — these were already locked during brainstorm.

**Builder confidence vs uncertainty:** confident about everything (the brainstorm + spec already adjudicated the choices). The three remaining "open questions" are tactical, not strategic: codegen tool choice (Quicktype vs hand-written vs Swift macros), image-similarity algorithm (Vision template match vs OpenCV ORB vs perceptual hash), Sparkle EdDSA key generation timing.

**Deepening-round payoff (in autonomous mode):** the architecture self-review surfaced three non-obvious edge cases that need /checklist items:
1. **Binding-mismatch UX** — the spec asserts `requires.bindings` is checked pre-flight, but doesn't specify the failure path. /checklist should add a UX item.
2. **Scaled-coord clamping** — resolution-scaling can produce coords slightly outside the window content rect; clamping must happen post-scale, pre-synth.
3. **Factory-patch local-edit detection** — the PRD AC says "warn if user has manually edited a factory-patchable macro," but the spec doesn't define HOW edits are detected. /checklist should add: store original-bundle hash at install time, compare before auto-update.

These are the kind of "what if" findings deepening rounds produce. Recording them as Open Issues in spec.md so /checklist consumes them.

**Subsystem-config pattern-match:** N/A — macRo is greenfield, not extending existing infra.

**Web research:** skipped in autonomous mode. The architectural choices reference current Apple APIs (ScreenCaptureKit is post-2023), Sparkle 2.x is current, EdDSA is the standard Sparkle 2.x signature scheme. Validated during brainstorm.

**Active shaping:** autonomous flow per the contract.

**Pattern note:** /spec produces ~250+ lines because it carries the heading-address structure /checklist consumes (every architectural component gets its own subheading). Bodies are pointer-stubbed to design spec, but the structural skeleton is faithful — that's the (mm) pattern's compression discipline at work.

**Friction / session logging:** still not invoked.
