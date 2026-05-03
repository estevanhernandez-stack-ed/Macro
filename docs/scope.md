# macRo

> **Spec-first cycle (Substrate (mm) pattern from cycle #13).** The full design lives at [`docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`](superpowers/specs/2026-05-03-macro-mac-app-design.md). This scope doc is the pointer-stub for downstream commands; trust the spec for any detail not surfaced here.

## Idea

The Mac macro maker for Roblox — a native Swift / SwiftUI app that records gameplay and ships diff-able, factory-patchable macros, with an iMovie-flavored authoring metaphor.

## Who It's For

**Primary v1 user:** the Roblox player who knows what macros do, has used other people's, and has never been able to author one from scratch. They're not a coder. They watch macro videos and download AHK scripts. They open Pet Simulator 99 every day. They want their own clan-battle helper, their own auto-hatch, their own auto-grind for the new biome — not someone else's. They're on a Mac.

**Specific unmet need:** Every existing macro tool (Psycho Hatcher, AHK community scripts, vibe-coded macro makers from the past year) is **Windows-first or Windows-only**. The Mac player has no native option. Even when they're willing to fight Wine / Parallels / a dual-boot setup, the authoring UX is script-first ("write your own .ahk") or record-and-pray (no editor, no gates, breaks on any UI change).

**Secondary user (v2+):** the community plugin author. Knows their game (Anime Defenders, Bubble Gum Sim Infinity, Adopt Me, whatever). Wants macRo to support their game without waiting for 626Labs to build a plugin. Author Kit lands v2/v3 with `.claude/` skills + a templated repo.

## Inspiration & References

- **Psycho Hatcher** — `psychohatcher.com`, Discord at `discord.gg/hRR3HpJR5h`, local copy of their feature catalog at `~/Downloads/Psyhco-Hatcher-main/`. The dominant Windows PS99 macro tool. AutoHotkey + IMAGES/ folders + per-mode subfolders + paid VIP tier. Architecturally validates our `.macro` bundle shape; locked to Windows by AHK; **not a code source** — competitive reference only.
- **iMovie / Final Cut Pro** — visual reference for the editor UX. Big preview top, scrubber middle, lanes below. The locked v2 mockup at `.superpowers/brainstorm/13966-1777822898/content/editor-shape-v2.html` (gitignored, local-only) shows the four-lane treatment: VIDEO / MOVE / ACTIONS / GATES.
- **Sanduhr für Claude** — existing 626Labs SwiftUI Mac app. Visual precedent for floating HUD overlays (RecorderHUD, RunHUD).
- **626Labs design system** — `~/projects/626labs-design/`. Dark navy + neon cyan/magenta + product-specific teal. Space Grotesk + Inter + JetBrains Mono. Voice: builder-to-builder, no emoji in UI, em-dashes welcome. Skill at `~/.claude/skills/626labs-design/`.
- **Apple ScreenCaptureKit + CGEventTap docs** — the modern (post-2023) APIs. WWDC sessions on SCK and the AVFoundation encode pipeline.

## Goals

The five moats from the spec, restated as builder-success criteria:

1. **The video-editor authoring surface ships and feels like iMovie**, not like opening a script editor. The target user records → cuts → exports without ever seeing YAML unless they want to.
2. **Mac-native posture holds end-to-end** — ScreenCaptureKit, CGEventTap, no Electron, no Tauri. Tiny binary, no battery hit, looks like a Mac app.
3. **Macros are diff-able text bundles** under the hood. The factory pipeline (Subsystem B, later cycle) can patch them in minutes after a game update because the schema is YAML + image refs, not opaque blobs.
4. **No telemetry, ever.** Anonymous GitHub release download counts (which we don't even own) are the only signal. This is part of the marketing pitch, not just an internal value.
5. **Accuracy-first factory**, when Subsystem B ships. Multi-candidate patch generation + sandboxed evaluation + only the highest-scoring candidate publishes. Never market a deadline; the public commitment is "patched correctly, fast."

What would make Estevan proud: macRo running his own clan-battle macro for Pet Sim 99, pulled from a recording he made in five minutes, with the factory keeping it valid through whatever the next Big Update throws at the game.

## What "Done" Looks Like

**v1 (this cycle's target):**

- Notarized DMG of macRo on GitHub Releases, downloadable, signed under Estevan's Apple Developer ID.
- First-launch entitlements wizard that walks the user through Accessibility + Screen Recording grants in plain English.
- Pet Sim 99 plugin pre-installed: `auto-hatch.macro`, `auto-grind-biome-1.macro`, `auto-rebirth.macro`, `auto-fuse-pets.macro`, `clan-battle-helper.macro` — all running against PS99 within 60 seconds of first launch (the wow moment).
- Recording flow: pick game → 3-2-1 countdown → record session → editor opens with the recording loaded into VIDEO/MOVE/ACTIONS/GATES lanes.
- Editor flow: trim cuts on the VIDEO lane → click an input event to refine → drop image-trigger gates from the snapshot library → save as a `.macro` bundle.
- Playback flow: pick a macro from the library → 3-2-1 countdown → engine runs with frame-rate-aware timing, gate-fail abort, schedule respect, stop-condition interrupts, and a global `⌃⌥⌘.` abort hotkey that always works.
- Sparkle 2.x auto-update wired to a GitHub-Pages-hosted appcast.
- Library panel reads from a static JSON feed at `https://macros.626labs.com/feed.json` (or a local override). Subsystem C swaps in a richer feed later without app changes.
- All factory hooks present in the bundle format (`factoryPatchable`, `versionFingerprint`, `patchHistory`, schema source-of-truth at `schema/macro.schema.yaml`) so Subsystem B drops in without retrofitting.

**Out of v1 (later cycles):** Subsystem B (factory pipeline) and Subsystem C (rich library — ratings, comments, browse-by-game). v1 ships the seams; the seams stay clean.

## What's Explicitly Cut

From spec § 11 "Out of scope for v1":

- **Subsystem B (factory automation)** — gets its own spec + cycle.
- **Subsystem C (rich library — browse / rate / fork / comment)** — v1 ships the static-JSON-feed stub.
- **Windows / Linux versions** — Mac-native is the moat. Cross-platform is a different product.
- **Mobile** — recording on iPhone is a different problem (no input synthesis APIs).
- **Macro marketplace / payments** — never in scope. Macros are free.
- **Cloud sync of user macros** — local-first, no auth, no accounts. Users share `.macro` bundles via Discord / AirDrop / whatever.
- **Variables / counters in the schema** — deferred to v2 schema bump (`schemaVersion: 2`). The "100 hatches then rebirth" use case can be expressed via `schedule` + `stopOn` for v1 without the counter surface.
- **OCR / number reading** — deferred to v2.
- **In-app community features** (comments, ratings) — Subsystem C.
- **Game support beyond Pet Sim 99 in-house** — engine is game-agnostic; only PS99 ships with a plugin in v1; community fills the gap from v2 onward.
- **Game Plugin Author Kit** — v2/v3.
- **Multi-instance Roblox client management** ("Psycho Manager"-style orchestration of many accounts) — real customer demand (Psycho Hatcher supports up to 100), but Roblox actively discourages it; v1 should not enter that contested ground. Architecture doesn't preclude adding it later.
- **Discord webhook notifications** (Psycho Hatcher ships a `WebHook` mode) — straightforward v2 enhancement to `stopOn.action`. Skipped in v1 because it forces a "user-supplied secret" flow we'd rather defer.
- **Auction / market sniping macros** (Psycho Hatcher's `Market Overlord`) — latency-sensitive single-action automation. Different problem shape than long-running grinds. v2+.

**Cuts NOT for "MVP smallness" — for principled reasons:** every cut above either (a) belongs in a different subsystem, (b) requires an opt-in we're choosing not to build (telemetry, accounts, payments), (c) compromises a moat (Mac-native), or (d) enters contested ground we'd rather not contest in v1 (multi-instance). None of them are "we'd love to ship X but ran out of time" — they're "X belongs somewhere else, or we deliberately don't want to ship X at all."

## Loose Implementation Notes

The spec is the definitive answer. Pointing at sections rather than paraphrasing:

- **Architecture:** Spec § 3 — layered (native services → domain → UI), four-thread discipline, `MacroFormat` module isolation as the lockstep contract with Subsystem B's TS types.
- **`.macro` bundle format:** Spec § 4 — folder-as-file via `LSItemContentTypes`, `manifest.yaml` + `timeline.yaml` + `gates/`, schema source at `schema/macro.schema.yaml`, factory-hook fields baked in.
- **Capture → edit:** Spec § 5 — three parallel recording streams (video / input JSONL / snapshots), draft bundle → editor with retroactive gate authoring.
- **Playback engine:** Spec § 6 — pre-flight checks (window, bindings, schedule, FPS, resolution), serial-queue run loop, gate semantics, abort hotkey `⌃⌥⌘.`, hard safety rules.
- **Distribution:** Spec § 7 — GitHub Releases, Sparkle 2.x EdDSA, notarize-in-CI, library JSON feed.
- **Visual treatment:** Spec § 8 — 626Labs design tokens via `MacRoTheme`, Sanduhr für Claude as SwiftUI precedent.
- **Plugin model:** Spec § 9 — three loader locations, community-authorable shape, Author Kit deferred.
- **PS99 v1 surface:** Spec § 10 — five seed macros, first-launch copy-into-library, plugin loader entry.

`/spec` should produce a thin spec-stub pointing at the design spec for substantive content (mm-pattern), and capture only the "what changed since the design spec was written" delta — which we'd expect to be near-zero given how recent the spec is.
