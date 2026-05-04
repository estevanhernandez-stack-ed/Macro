# macRo

> **Persona:** This repo inherits **The Architect** from `~/.claude/CLAUDE.md`. No need to re-establish — just adds project context below.

macRo is the Mac macro maker for Roblox. Native Swift/SwiftUI app first; TS/Bun factory pipeline second; macro library third. Pet Simulator 99 is the v1 anchor game; community-authored plugins ship from v2 onward. The contract that holds everything together is the `.macro` bundle format.

**The spec is the source of truth for *what* we're building.** This file is *how to work in this repo*. When the two diverge, the spec wins — fix CLAUDE.md, don't rewrite the spec from memory.

- **Design spec:** [docs/superpowers/specs/2026-05-03-macro-mac-app-design.md](docs/superpowers/specs/2026-05-03-macro-mac-app-design.md)
- **Status:** v1 design locked. Implementation pending. Next move is `/vibe-cartographer:scope` to enter the VC build flow.

---

## Tech Stack & Voice

- **Mac app:** Swift / SwiftUI. Native Apple APIs only — ScreenCaptureKit, CGEventTap, AVFoundation, NSAccessibility. No Electron, no Tauri, no cross-platform retrofit.
- **Factory pipeline (later):** TS / Bun. Lives at `tools/factory/` (path reserved, empty in v1).
- **Build:** Xcode for the Swift app. Bun for the factory. Single source of truth for the `.macro` schema lives at `schema/macro.schema.yaml` (when added) — Swift + TS types codegen from it.
- **Distribution:** Apple Developer ID signed + notarized DMG via GitHub Releases. Sparkle 2.x for auto-update. Notarize-in-CI via GitHub Actions.
- **Brand:** Cyan `#17d4fa` + magenta `#f22f89`, always paired. Deep navy field (`#091023`–`#192e44`). Product-specific teal `#2ee6c9` for primary CTAs and active nav. Space Grotesk display, Inter body, JetBrains Mono for code/meta (uppercase + 0.12em tracking on small labels).
- **Voice:** Builder-to-builder, second person, sentence case. Em-dashes welcome. No emoji in product UI or marketing copy. Periods at the end of microcopy. No "empower / leverage / seamlessly / unlock / unleash." Tagline: *Imagine Something Else.*

---

## Design system

Canonical brand spec lives at `~/.claude/skills/626labs-design/` (globally available — same skill across every 626 Labs repo) and at `~/projects/626labs-design/` (cloned source). Use `colors_and_type.css` as the token source and `ui_kits/` as the pattern reference. **Sanduhr für Claude** is the existing 626Labs SwiftUI Mac app — that's the visual precedent for HUD overlays in macRo (RecorderHUD, RunHUD).

When designing new screens, invoke the `626labs-design` skill rather than re-deriving tokens from memory.

---

## What's where

| Path | What it is |
| --- | --- |
| `README.md` | Public-facing intro. Links to the design spec. |
| `CLAUDE.md` | This file. How to work in this repo. |
| `docs/superpowers/specs/` | Design specs. The load-bearing one is `2026-05-03-macro-mac-app-design.md`. |
| `.gitignore` | Excludes `.superpowers/` (brainstorm artifacts), `.claude/settings.local.json`, build artifacts. |
| `.claude/` | Claude Code project config. `settings.local.json` is local-only; future `agents/`, `rules/`, `hooks/` are committed. |
| `.superpowers/` *(gitignored)* | Brainstorm session artifacts (mockups, visual companion screens). Useful local context; never commit. |
| `schema/macro.schema.yaml` | Single source of truth for the `.macro` bundle schema. Swift `MacroFormat` + (later) TS schema types codegen from this. |
| `App/` | Swift / SwiftUI app source. XcodeGen project at `App/project.yml` (the `.xcodeproj` is gitignored — regen with `cd App && xcodegen generate`). Layered: native services → domain (Recorder, Engine, MacroBundle, LibraryStore, Permissions, PluginLoader) → UI. `App/macRo/Schema/MacroFormat.swift` is GENERATED — never hand-edit. |
| `tools/codegen/` | Bun/TypeScript schema codegen. Reads `schema/macro.schema.yaml`, writes `App/macRo/Schema/MacroFormat.swift`. See `tools/codegen/README.md` for mapping decisions. |
| `games/pet-sim-99/` *(planned)* | First plugin. `plugin.yaml` + `seed-macros/` + README. |
| `tools/factory/` *(planned)* | TS/Bun factory pipeline. Empty in v1; gets its own spec. TS schema-types codegen will share `tools/codegen/` infra. |
| `tools/release/` *(planned)* | Notarization scripts + appcast generation. |
| `.github/workflows/ci.yml` | Schema-vs-types lockstep guard + Xcode build on macos-latest. Drift fails CI. |

Anything marked *(planned)* is described in the spec but not yet on disk.

---

## How macRo works at runtime (orientation, not duplication)

Three subsystems, sharing only the `.macro` bundle format as a contract:

- **Mac app (Subsystem A, v1)** — captures gameplay (synced video + input event stream + per-action snapshots), opens recordings in an iMovie-flavored timeline editor (VIDEO / MOVE / ACTIONS / GATES lanes), saves `.macro` bundles, plays them via a frame-rate-aware engine with safety gates and a global abort hotkey (`⌃⌥⌘.`).
- **Factory pipeline (Subsystem B, later)** — TS/Bun. Watches per-game patch feeds, generates **N candidate patches** for affected `factoryPatchable: true` macros, evaluates each against the new game state, ships the highest-scoring candidate. Accuracy-first, speed as internal motivation.
- **Library (Subsystem C, stub in v1)** — static JSON feed at `https://macros.626labs.com/feed.json`; in-app browse panel reads it. Anonymous GitHub release download counts are the only telemetry, ever.

Detailed architecture, schema, file format, playback engine semantics, and risk register all live in the spec. **Don't restate the spec here; reference it.**

---

## Common tasks

| You want to… | Path / command |
| --- | --- |
| Read the design spec | `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md` |
| Continue the VC flow (next step after brainstorm) | Invoke `/vibe-cartographer:scope` |
| Read the 626Labs design system | Invoke the `626labs-design` skill, or browse `~/projects/626labs-design/` |
| Inspect the Psycho Hatcher competitive reference | `~/Downloads/Psyhco-Hatcher-main/PH Final Version/` (Modes/, Settings/) |
| Log a significant decision | `mcp__626Labs__manage_decisions log` (when Dashboard MCP is connected) |
| Bind this repo to the 626Labs Dashboard | `mcp__626Labs__manage_projects findByRepo` with the remote URL (when MCP is connected) |
| Generate Swift types from the schema | `bun run codegen` from repo root (writes `App/macRo/Schema/MacroFormat.swift`). TS factory types regen will share the same script when `tools/factory/` lands. |
| Run the Mac app dev build *(planned)* | `xed App.xcodeproj` |
| Run the factory locally *(planned)* | `bun run dev` from `tools/factory/` |
| Build, sign, and notarize a release *(planned)* | `tools/release/notarize.sh` (or the GitHub Actions release workflow on `v*` tags) |

---

## Conventions

- **Commits:** Conventional commits — `feat`, `fix`, `docs`, `refactor`, `chore`, `spec`, `build`, `style`, `test`. The spec was committed as the initial commit; subsequent spec edits use `spec(scope): …`.
- **Style (Swift):** Swift API Design Guidelines. SwiftUI views in their own files. Domain types are Swift modules with no UI imports. Threading: capture / encoding on SCK's queue, input event tap on its own thread, engine playback on a dedicated serial queue, UI on main only.
- **Style (TS, factory):** Bun-first. Strict TypeScript. Match the 626 Labs TS conventions when they're established here (carry from sibling repos).
- **File rules:** `schema/macro.schema.yaml` is the canonical schema source — never hand-edit the generated Swift `MacroFormat` or TS schema types. The design spec at `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md` is the source of truth for product decisions; this CLAUDE.md is operational guidance, not a spec restatement.
- **Branch hygiene:** `main` is always shippable. Feature work happens in branches named after the spec section being implemented (e.g., `engine/playback-loop`, `editor/timeline-lanes`). Tag releases as `v0.1.0`, `v0.2.0`, etc.

---

## Decisions log

Significant decisions log to the **626Labs Dashboard** via MCP (`mcp__626Labs__manage_decisions log`). Tag with the bound project ID. The bar: *would future-you (or someone asking "why this approach?") want to know this in 3–6 months?*

Especially:

- **Schema changes** — anything that bumps `schemaVersion`, adds/removes a field on `manifest.yaml` or `timeline.yaml`, or alters a gate kind. The schema is the contract between three subsystems.
- **Plugin model decisions** — what's game-agnostic vs game-specific, how the plugin loader resolves conflicts, trust model for community plugins.
- **Engine semantics** — gate retry policy, frame-rate scaling caps, abort surfaces, safety rules.
- **Factory architecture choices** (when B begins) — patch candidate generation, scoring criteria, rollback behavior.
- **Visual treatment exceptions** — anywhere we deliberately diverge from the 626Labs design system or the established Sanduhr für Claude precedent.
- **Telemetry posture** — any change at all to "no telemetry, ever" requires a logged decision and an explicit user-facing disclosure.

Skip the routine: ran tests, fixed a typo, renamed an internal variable.

If the Dashboard MCP isn't bound: tag the decision with `repo: macRo` in the description and set `projectId: null` so the dashboard can surface it in the orphan-decisions view when it reconnects.

---

## What NOT to do

- **Don't restate the spec in CLAUDE.md.** When you need details about the architecture, schema, file format, engine semantics, distribution, or risks, read [docs/superpowers/specs/2026-05-03-macro-mac-app-design.md](docs/superpowers/specs/2026-05-03-macro-mac-app-design.md). Duplication rots; references stay current.
- **Don't break the schema-as-single-source-of-truth contract.** `schema/macro.schema.yaml` (when it exists) is canonical. Swift `MacroFormat` and TS schema types are generated from it. Hand-editing the generated types is a bug; either change the schema and regenerate, or accept that your edit will be wiped on next codegen.
- **Don't add anti-detection logic to the engine.** macRo has no anti-detection posture by design. The engine never obfuscates inputs, never injects into Roblox, never tries to evade observation. If a specific game introduces an active anti-macro check, adapt the plugin or stop supporting that game — never pollute the engine.
- **Don't introduce telemetry or phone-home behavior.** Anonymous GitHub release download counts are the only signal we collect, and we don't even own them — GitHub does. No analytics SDKs, no error reporters that ship without explicit per-incident consent. Any change here is a logged decision *and* a user-facing disclosure.
- **Don't break `factoryPatchable: true` semantics.** It's the user's opt-in to letting the factory touch their macro. Macros marked `factoryPatchable: false` are sacred — the factory ignores them entirely.
- **Don't compromise the Mac-native posture.** No Electron retrofit, no Tauri "for portability," no cross-platform abstractions that pretend macOS APIs don't exist. The platform is the moat.
- **Don't commit `.superpowers/`.** Brainstorm artifacts (mockups, visual companion sessions) are local-only context. They're already in `.gitignore`; keep them there.
- **Don't store signing keys, Sparkle EdDSA keys, or any secret in the repo.** Sparkle EdDSA key lives in 1Password per the spec. CI uses GitHub-hosted secrets. If you find a secret committed, rotate it before doing anything else.
- **Don't force-push to `main`.** Use feature branches and PRs. The single root commit on `main` is the spec landing — every subsequent change should be reviewable in the GitHub history.

---

## References

- **Design spec:** [docs/superpowers/specs/2026-05-03-macro-mac-app-design.md](docs/superpowers/specs/2026-05-03-macro-mac-app-design.md)
- **Brainstorm artifacts** (local-only, gitignored): `.superpowers/brainstorm/`
- **626Labs design system:** `~/projects/626labs-design/` (canonical source) and `~/.claude/skills/626labs-design/` (user-invocable skill)
- **Sanduhr für Claude** (sibling SwiftUI 626Labs Mac app): visual precedent for floating overlays. See `~/projects/Sanduhr_f-r_Claude/` (or wherever it lives on this machine) when designing HUDs.
- **The Architect persona + 626 Labs principles:** `~/.claude/CLAUDE.md`
- **Psycho Hatcher** (competitive reference, Windows-only AHK tool): `~/Downloads/Psyhco-Hatcher-main/`. Used for feature catalog and architectural validation only — not a code source.
