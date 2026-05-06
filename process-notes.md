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

## /checklist

Run mode: **autonomous** (carrying forward, but build mode itself surfaced to Estevan for explicit confirmation before /build runs).

**Sequencing decisions:** three Key Technical Decisions from spec drove the order — schema codegen first (item 2), engine before editor (items 5–6 before 8), PS99 plugin authored last (item 10). Item 6 is a deliberate verification beat — bridges items 5 (engine exists) and 7 (recorder exists) so the engine can be exercised against hand-authored fixtures before the recorder is built. Without item 6, the engine would have nothing to play against until the recorder lands, which means engine bugs would surface late.

**Build preferences encoded in header:**
- Build mode: Autonomous (default per `autonomy_level: fully-autonomous`; surfaced for builder confirmation)
- Comprehension checks: N/A
- Git: per-item commits with `feat(area):` / `docs(area):` / `chore(area):` prefixes
- Verification: Yes, three checkpoints at items 6, 8, 9
- Check-in cadence: N/A

**Three checkpoints chosen at the riskiest transitions:**
1. After item 6 — engine + native services + first hand-authored bundles working. Pre-recorder, pre-editor. The "is the runtime safe + correct?" gate.
2. After item 8 — recorder + editor + save flow integrated. The "can we author end-to-end?" gate.
3. After item 9 — library + install + auto-update + rollback. The "can we distribute + maintain?" gate.

After checkpoint 3, items 10 (plugin + seeds) and 11 (release pipeline) are well-trodden infra that the agent can ship without further pause. Item 12 is doc/security cleanup (always last).

**Item count: 12.** Within the SKILL's 8–12 target. Each item atomic enough for one /build session in iterative-prototype mode (some items, especially 4 and 5, may take 2 sessions — that's fine in autonomous + iterative-prototype).

**Documentation & security verification (item 12):** README rewrite + screenshots + tech-stack list + secrets scan + dependency audit + input-validation spot-check + Sparkle EdDSA signature enforcement check + GitHub Actions secret hygiene. Tag `v0.1.0` for first public release as part of this item.

**Confidence vs needs-guidance:** confident on the sequencing (the three Key Technical Decisions made it nearly mechanical). Needs Estevan input at three /build-time clarification points: (a) PS99 canonical keybindings during item 10's `plugin.yaml` authoring; (b) clan-battle macro mechanic during item 10's seed authoring; (c) build-mode confirmation BEFORE item 1 starts (autonomous vs step-by-step).

**Submission planning:** v0.0.1 internal test release at item 11; v0.1.0 first public release at item 12. The "Big Update Friday → patched macros Saturday" factory pitch is NOT v1; that's Subsystem B's spec, separate cycle.

**Active shaping:** autonomous flow per the contract. Substantive sequencing decisions were carried from the design spec's three Key Technical Decisions (which I authored during /spec but were really crystallized during the brainstorm + spec authoring upstream).

**Friction / session logging:** still not invoked.

## /build

Run mode: **autonomous** (locked at /checklist; confirmed by builder at the pre-/build inflection point in the prior session).

**Items 1–4 completed in the prior /build session.** Resumed by a fresh Claude Code session 2026-05-04. Items committed: `256922a` (item 1), `4acc624` (item 2), `0ba38d6` (item 3), `266a4db` (item 4). Three untracked support files for item 5 (`AppShortcutMonitor.swift`, `EngineErrors.swift`, `EngineLogger.swift`) carried over from the prior session, uncommitted.

### Item 5 — `sequence_revised: medium` mid-build

**What broke:** First subagent dispatch for item 5 timed out at 64-min wall-clock with 29 tool uses and **zero source files written** to disk. Stream-idle timeout. Working tree was identical to entry. Subagent burned its window on context-loading without producing committable artifacts.

**Root cause:** item 5 as scoped (Engine.swift core + RunHUD + BindingMismatchPrompt + App.swift wiring + XcodeGen regen + smoke tests + build verification + commit) is genuinely too much for a single subagent dispatch when full architectural context (spec § 6, PRD epic D, builder profile, three pre-existing files, native services, MacroFormat module, MacRoTheme) needs to be loaded cold before any writes start.

**Per the SKILL's "When Something Breaks" protocol:**
1. Stopped immediately. ✓
2. Surfaced honestly to builder with three options (split / orchestrator-builds-directly / stop-and-clear). ✓
3. Damage assessment: zero damage, working tree clean, only the three pre-existing untracked files. ✓
4. Builder chose **Option A — split item 5 into 5a / 5b / 5c**, three smaller dispatches with finer granularity. ✓
5. Checklist updated with the revised plan: 5a (Engine.swift core), 5b (UI + wiring + XcodeGen regen), 5c (smoke tests + xcodebuild verify + commit + checklist mark). ✓
6. Friction logged as `sequence_revised: medium` in this process-notes entry (VC's friction-logger infra still not bootstrapped on this machine; this is the established surrogate). symptom: `"item 5 single-dispatch timed out at 64min/29 tool uses with zero on-disk output; split into 5a (Engine core) / 5b (UI + wiring) / 5c (tests + commit) for finer subagent granularity, same architectural plan."`
7. Resuming with 5a dispatch. ✓

**Pattern note for /evolve to consider:** subagent dispatch for autonomous /build items has a **context-load tax** (full spec + PRD + builder profile + relevant existing files). When an item's deliverable surface is wide (>4 distinct files of significant LoC), the dispatch tax can consume a meaningful fraction of the available window before substantive work starts. Heuristic for future /checklist authoring: items with >4 substantive deliverables benefit from being authored as sub-items (Na/Nb/Nc) at /checklist time, not waiting for a /build-time break-and-revise. Documented here for the cycle-14 /reflect pass to surface as a candidate Substrate pattern.

**Friction / session logging:** still not invoked at the formal VC layer (infra not bootstrapped on this machine); recorded inline as established surrogate.

### UX additions captured 2026-05-05 — Quick-loop save flow (item 7.5 inserted)

**Builder directive (verbatim):**

> "if a user just recorded a simple throwaway macro or simple macro, they're can use just they go in themselves, get themselves to where they wanna be. They start the macro recorder. They hit a couple of keys that they have, linked to hot keys in the game, and it executes things and they just want that to run on a loop. It should be that easy for them. They should be able to, put a timer between when it repeats the same their same actions without having to edit the whole thing. And then if they wanna edit the whole thing, the editor."

**Why this lands now (between items 7 and 8):**

The post-record UX in 7b is currently a single-button "Recording saved" alert. That's correct for the wizard-flow but wrong for the casual user who recorded a 3-keystroke loop and just wants it to repeat forever. Forcing them through the editor to add a `loop` event is friction; the editor is the wedge for nontrivial macros, not table stakes for the simplest case.

**Item 7.5 inserts a 3-option post-record sheet between item 7 (recorder) and item 8 (editor):**

- **Save** — current behavior (one-shot, raw timeline)
- **Save as loop** — append a `loop {target: 0.0, delayMs: <user-input ms>}` event to the timeline, save the bundle. Zero editor visit. Requires a v1 schema addition (`delayMs: Int?` optional field on the `loop` event) + Engine dispatch update to honor the delay between jumps.
- **Open in Editor** — placeholder until item 8 lands; for now opens Finder.

**Pattern observation for /evolve:** the "casual user wants the simplest thing" insight tends to surface at empirical-test time, not at /scope or /prd time. PRD epic B captured "record + save + EditorView loads" as the canonical flow but didn't enumerate the zero-edit-loop case. Building the recorder, recording a real macro, and confronting "now what?" is what surfaced this. Pattern candidate: **after every checklist item that produces a user-facing surface (recorder, editor, library), a deliberate "casual user happy path" review beat catches missing zero-friction paths.**

**Schema impact:** `loop` event gets an optional `delayMs: Int?` field. Backward-compatible (existing macros without the field default to 0 = immediate jump, matching today's behavior). `bun run codegen` after the schema edit; CI lockstep guard catches any drift.

**Engine impact:** `Engine.swift`'s loop-event dispatch path needs to honor `delayMs` — sleep on the engine serial queue between jump-to-target and resuming the run loop. Currently the loop case is structurally an immediate jump; adding a delay is a single `try? await Task.sleep(...)` (or its DispatchQueue equivalent on the engine queue).

**Friction / session logging:** still not invoked at the formal VC layer (infra not bootstrapped on this machine); recorded inline as established surrogate.
