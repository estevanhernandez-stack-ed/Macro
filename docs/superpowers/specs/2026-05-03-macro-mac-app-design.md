# macRo — Mac App Design Spec

**Date:** 2026-05-03
**Status:** Brainstorm complete, design locked, ready for implementation planning
**Owner:** Estevan Hernandez (626 Labs)
**Authoring agent:** The Architect (Claude Opus 4.7) via superpowers:brainstorming
**Next step:** Hand to `/keystone` (bootstrap CLAUDE.md), then `/vibe-cartographer:scope` for the VC-flow PRD/spec/checklist/build cycle.

---

## TL;DR

macRo is a **Mac-native macro maker and player for Roblox**, anchored on Pet Simulator 99 for v1. Three-subsystem architecture: a Swift/SwiftUI app (this spec), a TS/Bun factory pipeline (later spec), and a static-feed library (later spec). The wedge is a **video-editor authoring metaphor** — record gameplay, scrub the timeline like iMovie, cut the dead air, the inputs in what's left become the macro. Macros are diff-able text bundles (`.macro` folders) so the factory can patch them quickly and accurately when games update. **No telemetry**, ever — only GitHub's anonymous download counts. **Game plugins beyond Pet Sim 99 are community-authored**, with a 626-shipped author kit landing in v2/v3.

The five moats are: (1) the video-editor authoring surface, (2) Mac-native ScreenCaptureKit-era APIs, (3) diff-able text macro format, (4) no telemetry as a feature, (5) the factory's accuracy-first patching pipeline.

---

## 1. Project context

### What we're building (and why this shape)

The user (Este) has used other people's macros via AutoHotkey but has never been able to author his own. The recent crop of vibe-coded macro makers exists, but the authoring UX is script-first or record-and-pray — neither approachable for the player who knows what macros do but can't write code. macRo is the **iMovie of macro authoring**: record the gameplay, edit a video timeline, ship a macro. Power users can drop into a YAML script view; everyone else lives in the timeline.

The "build a codebase ready to ship new macros lightning-fast after weekly game updates" goal becomes a **factory pipeline** (Subsystem B, later spec) that depends on macros being diff-able text bundles. This spec covers the local Mac app (Subsystem A) and leaves clean hooks for B and C (the library, Subsystem C, later spec).

### 626 Labs principles that bind this design

- **No telemetry, ever.** Server-side anonymous download counts (GitHub's, not ours) and a "submit a concern" path are the only feedback channels. No phone-home from the app, no analytics SDK, no crash reporter that ships data without explicit per-incident consent.
- **Mac-native is the moat.** Swift/SwiftUI, ScreenCaptureKit, CGEventTap. Not Electron, not Tauri.
- **Builder-to-builder voice and 626Labs visual system.** Dark-mode first, neon duotone (cyan + magenta), product-specific teal for CTAs, Space Grotesk + Inter + JetBrains Mono.
- **Diff-able artifacts wherever possible.** Macros are YAML + image refs in a folder bundle; the factory and humans can both work on them.
- **Accuracy-first, speed as internal motivation.** Public commitment is "correctly patched, fast." Never market a deadline.

### Roblox posture

Roblox itself does not actively ban input-based macros (per Este's direct experience). macRo has **no anti-detection posture by design**; the engine never obfuscates inputs, never injects into Roblox's process, never tries to evade observation. If a specific game introduces an active anti-macro check, we treat it like any other game-specific challenge — adapt the plugin or stop supporting that game.

---

## 2. System overview

macRo is **three subsystems**, built and shipped in order. They share only the macro file format.

| Subsystem | What it owns | Stack | Ships in |
| --- | --- | --- | --- |
| **A — Mac app** | Capture, edit, playback | Swift/SwiftUI | v1 (this spec) |
| **B — Factory pipeline** | Detect game updates, patch affected macros, publish | TS/Bun | Later spec |
| **C — Library** | Discover, install, auto-update macros | Static JSON feed + in-app browse | v1 stub, later spec for full surface |

**The contract that holds them together:** the `.macro` bundle format (Section 4). As long as that's stable and `schemaVersion`-versioned, the three subsystems ship and evolve independently.

**For v1 (this spec) we ship Subsystem A only**, with deliberate hooks for B and C:
- Bundle format includes `factoryPatchable: true` opt-in field
- Bundle path layout matches what B will consume: `<game-slug>/<macro-id>.macro`
- The in-app library panel is functional against a static JSON feed (which can be a local file in v1, a 626Labs-hosted file later); C swaps in a richer feed without app changes.

---

## 3. Mac app architecture

### Layered, with strict downward-only dependencies

**Native services layer** — thin Swift wrappers over Apple APIs.
- `ScreenCaptureKit` for capture (hardware-accelerated, modern, requires one-time permission grant)
- `CGEventTap` + `CGEvent.post` for input record + synthesis (requires Accessibility permission)
- `AVFoundation` for encode/decode of recording video
- `NSWorkspace` + `AXUIElement` for detecting the active Roblox window and current game

**Domain layer (Swift, no UI imports)**
- `Recorder` — drives capture session, owns the recording timeline, writes raw artifacts to a working dir
- `MacroBundle` — load/save the `.macro` folder, schema validation, versioning
- `Engine` — playback runtime. Reads `MacroBundle`, drives gates + input synth, frame-rate-aware timing, abort handling
- `LibraryStore` — local macro inventory + (stubbed) remote feed
- `Permissions` — requests + checks Accessibility + Screen Recording entitlements; drives first-launch flow
- `PluginLoader` — indexes game plugins from app-bundled, user-installed, and URL-installable sources

**UI layer (SwiftUI)**
- `RecorderHUD` — small draggable overlay during recording (timer, abort)
- `EditorView` — the iMovie-flavored timeline editor (Section 5)
- `LibraryView` — browse local + remote macros
- `RunHUD` — minimal playback overlay (countdown, stop)
- `OnboardingView` — first-launch entitlements wizard

**Cross-cutting**
- `MacroFormat` — schema types module. Code-generated from `schema/macro.schema.yaml` (single source of truth shared with Subsystem B). Domain + UI both depend on it; nothing depends on UI; the schema module has no dependencies.
- `MacRoTheme` — SwiftUI theme that maps 626Labs design tokens to SwiftUI types. See Section 8.

### Threading discipline

| Concern | Thread/Queue |
| --- | --- |
| Capture + encoding | ScreenCaptureKit's own queue, never main |
| Input event tap | Dedicated thread (CGEventTap blocks the run loop) |
| Engine playback | Dedicated serial queue (synthesis must be paced) |
| UI | Main, period |

### The clean contract

`MacroFormat` is a separate Swift module containing only the bundle schema types. Both the domain layer and the UI layer depend on it; nothing depends on the UI layer; the schema module has no external dependencies. This is what lets Subsystem B (TS/Bun) generate compatible bundles — the YAML schema is the source of truth, the Swift `MacroFormat` types are derived from it via codegen in CI.

---

## 4. The `.macro` bundle format

### On disk

A folder with a `.macro` extension. macOS treats it as a single file in Finder via Info.plist `LSItemContentTypes` registration. CLI sees it as a folder.

```
auto-fish-bloxfruits.macro/
├── manifest.yaml          # metadata: id, name, game, version, author, schemaVersion, factoryPatchable
├── timeline.yaml          # the event stream (text, diff-friendly)
├── gates/                 # PNG snapshots referenced by gate IDs
│   ├── pos-fishing-spot.png
│   ├── img-catch-prompt.png
│   └── img-reel-prompt.png
└── preview.mp4            # OPTIONAL low-res ~5MB video for library browse
```

### `manifest.yaml`

```yaml
id: ps99-auto-hatch-v1
name: "Auto-hatch (Tech Town Eggs)"
description: "Hatches at Tech Town egg row, auto-pauses on Mythic, auto-equips best 6."
game:
  placeId: 8737899170                    # Roblox place ID (optional; untagged macros omit)
  name: "Pet Simulator 99"
  versionDetectedAt: "2026-05-03T14:22:00Z"
  versionFingerprint: "v1.27.4-detected"
author: "Este"
version: "1.0.0"
schemaVersion: 1
factoryPatchable: true                    # opt-in to auto-patching
estimatedRuntime: "indefinite"            # or "00:02:17" for finite macros
recordedFrameRate: 60
target:
  windowClass: ["RobloxApp", "Roblox"]    # array of fallback NSAccessibility classes
  windowTitleMatch: "Roblox"              # regex; engine asserts before play
  coordinateSpace: window                 # all click x,y are window-relative, not screen
  recordedResolution: { width: 2560, height: 1440 }   # the resolution the macro was recorded at
  resolutionPolicy: scale                  # scale | anchor-to-window | image-anchored
requires:
  bindings:
    - { action: "interact", expected: "E" }
    - { action: "menu",     expected: "Tab" }
schedule:
  - between: { from: "22:00", to: "06:00", timezone: local }
patchHistory: []                          # factory appends entries
```

### `timeline.yaml`

```yaml
events:
  - { t: 0.000, kind: keyDown, key: w }
  - { t: 3.520, kind: keyUp,   key: w }
  - { t: 3.700, kind: gate, gateKind: pos, ref: pos-fishing-spot, retries: 3, onFail: abort }
  - { t: 3.800, kind: cameraDelta, dx: -120, dy: 0, duration: 0.6 }
  - { t: 4.500, kind: click, x: 640, y: 412, button: left }
  - { t: 5.100, kind: gate, gateKind: img, ref: img-catch-prompt, timeout: 30, onFail: continue }
  - { t: 5.200, kind: keyPress, key: e }
  - { t: 6.000, kind: loop, label: main, target: 3.700 }

stopOn:
  - when: { gateKind: img, ref: img-mythic-banner }
    action: pause
    message: "MYTHIC HATCHED — paused for you"
  - when: { gateKind: img, ref: img-disconnect-dialog }
    action: sub:reconnect

subs:
  cleanup-inventory:
    events: [ ... fuse / sell / delete loop ... ]
  reconnect:
    events: [ ... reconnect flow ... ]
```

### Why this shape

- **YAML, not JSON** — comments, anchors, less ceremony. Humans (and the user in script-view) can read+edit.
- **Absolute times** instead of deltas — easier diffs, easier scrubbing, easier loop targeting.
- **Gates are first-class events** — not metadata sprinkled on input events. Engine just walks the timeline; gate events stop the walk until satisfied (or fail).
- **Image refs by ID, not path** — factory can swap PNGs in `gates/` without touching `timeline.yaml`. Diff stays clean.
- **`factoryPatchable: true` is opt-in** — user can lock a macro to "don't auto-patch me, I tuned this myself."
- **`schemaVersion`** — non-negotiable for the factory's longevity. Engine refuses to play unknown schema versions.
- **`stopOn` + `subs`** — interrupt-driven control flow without needing a full programming language.

### Schema source of truth

A single YAML schema file lives at `schema/macro.schema.yaml` in the repo. CI generates Swift `MacroFormat` types and TS schema types from it. This is the lockstep guarantee between Subsystems A and B.

### v1 schema includes

- Stop conditions (`stopOn`)
- Schedule windows (`schedule`)
- Sub-macros and branches (`subs`, `invokeSub`)
- Window targeting (`target.windowClass`, `target.windowTitleMatch`, `target.coordinateSpace`)
- Resolution awareness (`target.recordedResolution`, `target.resolutionPolicy`)
- Game version pin + required bindings (`game.versionFingerprint`, `requires.bindings`)
- Gates (POS + IMG), `factoryPatchable`, `patchHistory`

### Deferred to v2 schema bump (`schemaVersion: 2`)

- Variables / counters (`vars`, `incVar`, gate-on-var)
- OCR / number reading
- Multi-monitor regions beyond window-targeting
- Sound resources (alert sounds)
- Macro composition (`include: other.macro`)

---

## 5. Capture → edit flow

### Capture (Recorder)

1. User picks a game from a quick "what game?" sheet (Pet Sim 99 selected by default for v1; "Untagged / general" available). Game choice locks `target.windowTitleMatch` and `target.windowClass` so the window-targeting field gets populated automatically — user never types selectors.
2. macRo waits for the matching Roblox window to become frontmost, then shows the **RecorderHUD** — small draggable overlay with: timer, abort button, "add image-trigger here" hotkey hint.
3. User clicks Record (3-2-1 countdown so the user can refocus the Roblox window).
4. Three streams write to a working dir in parallel:
   - **`raw-video.mov`** via ScreenCaptureKit — captures the Roblox window content rect only (not whole screen, not the HUD)
   - **`raw-input.jsonl`** via CGEventTap — every keyDown/keyUp/click/cameraDelta with monotonic timestamps in window-relative coords
   - **`snapshots/`** — automatic frame snapshots at every input event AND every 1 second (cheap to grab via SCK; lets the editor add gates retroactively at any timeline point)
5. User hits the abort hotkey or HUD stop button. Recorder finalizes the streams and opens the working dir as a **draft bundle** in EditorView.

### Edit (EditorView — the iMovie-flavored timeline)

**Layout (locked in v2 mockup):**

| Lane | Contents |
| --- | --- |
| **VIDEO** | Cut/keep regions of the recorded video. Drag handles at edges to trim. |
| **MOVE** | Held-key bars (WASD) with duration visible; camera/mouse-look as separate bars. *This is the lane that ensures the character lands where actions expect it.* |
| **ACTIONS** | Mouse clicks (•) and key/hotkey presses (boxed glyphs). Position-dependent. |
| **GATES** | ◇ POS (verify-position-by-image) and ◆ IMG (wait-for-UI-cue) markers. |

**Behaviors:**
- **Cuts** in the VIDEO lane drop the corresponding input events from the timeline AND skip the time range entirely (playback time compresses, not stretches).
- **Click an input event** in MOVE/ACTIONS → inspector panel opens on the right. Edit timing, swap "click at x,y" for "click on image-of-this-button," add jitter (humanize timing ±50ms), or delete.
- **Click "+ image-trigger"** on the timeline → editor pops a "click the part of the frame to wait for" cropper using the existing snapshot for that timestamp. Cropped image saved as `gates/img-<id>.png`; gate event inserts at that time.
- **Click "+ position-trigger"** → same flow, cropped region annotated as a position cue.
- **Toolbar panels:** `subs:` (build inventory-cleanup sub-macro inline), `stopOn:` (build interrupts), `schedule:` (set time windows). Each is a small SwiftUI form that writes to the YAML model.
- **Script view** — toggle to a Monaco-style YAML editor with schema validation. Power users live here. Round-trips losslessly with the timeline view.

### Save

- "Save" packages the working dir into the final `.macro` bundle (drops uncut video frames from `snapshots/`, keeps only those referenced by gates), writes `manifest.yaml` and `timeline.yaml`, optionally encodes `preview.mp4` from the kept video segments.
- **Default save location:** `~/Library/Application Support/macRo/Library/<game-slug>/<macro-id>.macro`. Library panel sees it immediately.

---

## 6. Playback engine

### Pre-flight (before any synthesis)

1. **Schema version check** — if `schemaVersion` exceeds engine's supported version, refuse with explanation. (Forward compat is the factory's job; back compat is the engine's promise.)
2. **Window match** — wait up to 10s for a window matching `target.windowTitleMatch` to be frontmost. If timeout, alert and exit.
3. **Required bindings check** — read user's Roblox key bindings if Roblox exposes them; otherwise show "macro expects E=Interact, Tab=Menu — confirm these match your bindings before continuing" modal once per macro.
4. **Schedule check** — if current time is outside `schedule:` windows, engine enters **paused** state and waits, doesn't run.
5. **Frame-rate sample** — capture 1s of SCK frames, compute observed FPS, store as `runtimeFrameRate`. All held-key durations get scaled by `recordedFrameRate / runtimeFrameRate` (cap at 0.5x–2x to avoid silliness). User can override with a manually-entered FPS in Settings if auto-detect drifts.
6. **Resolution scaling** — read current Roblox window content rect, compare against `target.recordedResolution`. If `resolutionPolicy: scale`, all click coords get scaled proportionally `(currentWidth/recordedWidth, currentHeight/recordedHeight)`. If `image-anchored`, click coords are recomputed at runtime from the most recent gate's image-search result. If `anchor-to-window`, coords are used as-is window-relative (only safe when resolutions match). Engine warns the user when running a macro at a resolution it wasn't recorded at, even with scaling enabled.

### Run loop (single dedicated serial queue)

Walk the timeline. For each event:

- **Input event** (keyDown, keyUp, click, cameraDelta) → translate window-relative coords to screen coords using current Roblox window frame, synth via `CGEvent.post`. Apply jitter if specified. Sleep until next event's `t`.
- **Gate event** → enter **gating** state. Capture frame snapshot via SCK. Compare against gate ref image (template match algorithm TBD during prototype: Vision template match vs OpenCV ORB vs perceptual hash). ~95% similarity threshold for IMG, ~85% for POS (POS is looser because environment lighting varies). Retry up to `gate.retries` with backoff. On success, continue. On failure, take `onFail` action.
- **Loop event** → bump visit count for that label; if visit count exceeds engine's runaway threshold (default 100,000, configurable per macro), abort with "loop runaway" reason. Otherwise jump playhead to target time.
- **InvokeSub event** → push current position onto sub-stack, jump to sub's first event. On sub completion, pop and resume.

### Stop conditions (interrupts)

Run loop *also* polls `stopOn:` triggers every 500ms in parallel. When any matches, engine takes the configured action: `pause` (freeze, show notification), `exit` (clean stop), or `sub:<name>` (run sub, then resume main).

### Abort surfaces (always available, never blockable)

- **Global hotkey:** `⌃⌥⌘.` (Control+Option+Command+Period). Registered as a system-level NSEventMonitor, fires even when Roblox has focus. Hard to hit accidentally, trivial on purpose. Period chosen because games rarely bind it.
- **RunHUD stop button** — small overlay in screen corner, always click-throughable on the rest of the screen.
- **Window-lost trigger** — if the target window goes background or closes mid-run, engine **pauses** (not aborts) and shows "Roblox window lost — bring it back to resume."

### State machine

```
idle → preflight → (paused waiting on schedule) → running ↔ gating → finished | aborted | failed
```

Each state transition writes a line to `~/Library/Application Support/macRo/Logs/<run-id>.log`. Local only, no phone-home, user can delete the log dir without consequence. The factory and library never see these logs.

### Hard safety rules

- Engine **never** synthesizes input while macRo's own UI is frontmost (would let a recorded macro click "Quit" on macRo itself).
- Engine **never** synthesizes input outside the target window's content rect (clicks can't land on the menu bar, Dock, or other apps).
- Maximum continuous run time is configurable per macro (default unlimited, but `manifest.maxRuntimeHours` lets the author cap it).
- All input synthesis goes through one chokepoint method that logs the event — easier to audit, easier to test.

---

## 7. Distribution + factory hooks

### App distribution

- **GitHub Releases** as the canonical channel. Apple Developer ID signed + notarized DMG, attached to each tagged release. Free anonymous download counts (the only telemetry we tolerate, owned by GitHub not us).
- **Sparkle 2.x for auto-update.** Sparkle reads an `appcast.xml` hosted on GitHub Pages (or in the release feed itself). EdDSA-signed updates, no third-party update server, zero phone-home beyond the appcast fetch.
- **First launch:** entitlements wizard (Accessibility, Screen Recording — both required, both explained in plain English with screenshots). User can't skip; macRo does nothing without them. Opens System Settings deep-link if denied.
- **Code-signing pipeline:** `tools/release/notarize.sh` + GitHub Actions workflow tagged on `v*`. Notarization happens in CI so we don't depend on a single laptop being available.
- **Sparkle EdDSA key:** generated at first release, stored in 1Password, recovery flow documented in `docs/release/`.

### Macro distribution (Subsystem C, stubbed but functional in v1)

Library panel reads two sources:

1. **Local:** `~/Library/Application Support/macRo/Library/<game-slug>/*.macro`
2. **Remote feed:** a single JSON manifest fetched from a configurable URL (default `https://macros.626labs.com/feed.json`)

Remote feed shape (intentionally trivial so v1 ships):

```json
{
  "schemaVersion": 1,
  "macros": [
    {
      "id": "ps99-auto-hatch-v1",
      "game": "Pet Simulator 99",
      "version": "1.0.0",
      "downloadUrl": "https://macros.626labs.com/ps99/auto-hatch-v1.macro.zip",
      "sha256": "a1b2c3...",
      "factoryPatchable": true,
      "lastUpdated": "2026-05-03T14:00:00Z"
    }
  ]
}
```

**Install flow:** click → download bundle → verify SHA-256 → write to local Library dir → done.
**Auto-update for macros:** re-poll feed every launch, prompt user when a `factoryPatchable: true` macro has a newer version. Default to "auto-update yes" with one-click rollback to previous version available in the Library panel.

For v1 the JSON lives as a static file in a 626Labs-owned bucket. Subsystem C later replaces it with whatever (CMS, dynamic API, GitHub Releases mirror) — the app doesn't care because it just reads JSON.

### Factory hooks left in v1 (so Subsystem B drops in clean later)

- **Single schema source of truth** at `schema/macro.schema.yaml` in the repo. Swift `MacroFormat` types and TS schema types are both code-generated from it. Lockstep guaranteed by CI.
- **Bundle naming convention** locked: `<game-slug>/<macro-id>.macro`. Factory addresses macros by slug+id without parsing.
- **`factoryPatchable: true` field** is the opt-in — factory only touches macros that say it can.
- **`game.versionFingerprint` field** carries whatever version signal the factory can sniff (a hash of UI screenshots, a recognized HTML banner, whatever B decides). Engine doesn't read it; factory writes/reads it.
- **Reserved repo paths** for B's future code: `tools/factory/` (Bun project, empty in v1 except for a README describing its job and the contract it'll honor).
- **`patchHistory: []` field** in `manifest.yaml` — factory appends entries `{ date, fromVersion, toVersion, patchedBy, notes }` so users can see "this macro was last patched by the factory on 2026-06-15."

### The factory promise (restated correctly)

> Factory walks every `factoryPatchable: true` macro affected by a detected game update. **For each affected macro, it generates N candidate patches**, evaluates each against the new game state (regenerated gates' actual match scores; timing replayed in a sandboxed test environment), commits only the highest-scoring candidate, signs, publishes.
>
> **Speed is internal motivation; accuracy-first is the public commitment.** The factory ships when the patch is right, not when the timer hits.

This mirrors how Este authors with Claude Code: explore N approaches, score them, ship the best. Subsystem B is an evaluator, not just a patcher.

---

## 8. Visual treatment

### Source of truth

The 626Labs design system, cloned at `~/projects/626labs-design`. The `626labs-design` Claude Code skill (installed at `~/.claude/skills/626labs-design`) is invoked when designing new screens during build.

### Foundations

- **Dark-mode first.** Deep navy base (`#091023`–`#192e44`).
- **Signature duo:** neon cyan `#17d4fa` + magenta `#f22f89`. Always paired in any visual treatment that uses them.
- **Product-specific accent:** teal `#2ee6c9` for primary CTAs and active nav (matches The Lab Dashboard treatment).
- **Type:** Space Grotesk (display), Inter (UI), JetBrains Mono (code + small meta labels, always uppercase with +0.12em tracking).
- **Voice:** builder-to-builder, second-person, short sentences, em-dashes welcome, no emoji in product UI, periods at the end of microcopy.

### macRo-specific surfaces

- **EditorView** lanes use the brand palette: VIDEO lane in deep navy with teal kept-segments and dimmed gray cuts; MOVE lane bars in the cyan/magenta duo (cyan for movement keys, magenta for camera deltas); ACTIONS lane dots in white; GATES markers in the warning amber (or use the brand magenta for IMG, brand cyan for POS — final call during build).
- **RecorderHUD** and **RunHUD** use the JetBrains Mono uppercase tracking for the timer; teal stop button.
- **Onboarding/Permissions screens** use full brand identity — logo lockup, tagline-adjacent copy ("Imagine Something Else" applies).
- **Library panel** mirrors The Lab Dashboard's card density and badge treatment.

### SwiftUI implementation

All UI components inherit from a shared `MacRoTheme` struct that maps 626Labs design tokens to SwiftUI types (Color, Font, EdgeInsets, RoundedRectangle radius values). When a new screen is built, the design skill is invoked to generate a SwiftUI scaffold consistent with the system. Nothing in macRo's UI uses Apple's default styles directly — `.tint()`, `.font()`, `.background()` always reach through `MacRoTheme`.

### Reference precedent

**Sanduhr für Claude** is an existing 626Labs SwiftUI Mac app. Used as the visual reference for floating overlay treatments (RecorderHUD, RunHUD). Its repo and styling conventions are the precedent macRo follows — confirm via direct read during build phase.

---

## 9. Plugin model

### The model

626 Labs ships the Pet Simulator 99 plugin (and possibly one or two other plugins for games Este personally plays). **Every other game's plugin is community-authored.** macRo doesn't try to be expert in 50 Roblox games — it makes it easy for the people who already are.

### Why this is right

The Roblox game catalog is enormous and shifts weekly. Trying to maintain plugins for all of them in-house is a treadmill. Letting the community plug in mirrors how the rest of the macro ecosystem already works (community-shared AHK scripts, community-maintained game wikis), but does it with a Mac-native, factory-backed substrate that the community alone can't build.

### v1 plugin loader requirements

The plugin loader must look in **three** locations:

1. **App-bundled** — `games/` in the app resources. Ships with PS99.
2. **User-installed** — `~/Library/Application Support/macRo/Plugins/`. For community plugins.
3. **URL-installable** — `macRo install plugin <url-or-git>` CLI command (no in-app UI in v1, that's v2; CLI exists so the path is real).

Loader indexes plugins by `placeId` and offers them in the "what game?" sheet at recording time.

### Plugin shape (community-authorable)

```
games/<plugin-slug>/
├── plugin.yaml            # placeId, displayName, windowMatchers, defaultBindings, pluginVersion, compatibleEngineVersion
├── seed-macros/           # canonical macros that ship with the plugin
│   ├── *.macro
└── README.md              # what's specific, why
```

`plugin.yaml` is the *only* game-specific config the engine reads — and it reads it through the generic plugin loader, not via hardcoded if-game-is-X. The `pluginVersion` and `compatibleEngineVersion` fields are present from day one so future plugins can declare engine compatibility.

### Trust model for community plugins

- Plugins are not code. They're YAML + image assets + `.macro` bundles. No executable surface, no code injection vector.
- macRo still treats unsigned community plugins with a Gatekeeper-style "first-launch" warning: "This plugin was authored by `<author>`. Review the README before using." User can dismiss with a checkbox.

### Deferred to v2 or v3 — Game Plugin Author Kit

A 626-shipped product surface for community plugin authors:

- **Templated repo:** `gh repo create --template 626Labs/macro-plugin-template`
- **Pre-configured `.claude/` skills** for plugin authoring (e.g., `/scaffold-plugin`, `/test-plugin`, `/diff-against-game-update`)
- **VS Code workspace settings** + recommended extensions
- **Test harness** — verify plugin loads, verify seed macros play in a sandboxed Roblox window
- **Documentation** — "Author a macRo plugin in an evening, with or without Claude Code"

The kit is its own product surface (small, real). v1's plugin loader is built knowing this is coming so we don't paint into a corner.

---

## 10. Pet Simulator 99 — v1 surface

### Why Pet Sim 99

Always-grinding loop, huge audience, well-understood macro use cases (auto-hatch, auto-grind biome currency, auto-rebirth, clan-battle helper). The factory promise gets pressure-tested against the game's "Big Update drops Friday → community needs working macros by Saturday" cadence.

### What ships in `games/pet-sim-99/`

```
games/pet-sim-99/
├── plugin.yaml            # placeId 8737899170, displayName, window matchers, default bindings
├── seed-macros/
│   ├── auto-hatch.macro              # long-running, inventory-sensitive, Mythic-interrupt demo
│   ├── auto-grind-biome-1.macro      # position-critical, MOVE-lane demo
│   ├── auto-rebirth.macro            # UI-cue-heavy, GATES-lane demo
│   ├── auto-fuse-pets.macro          # subs: + stopOn: combo demo (Psycho Hatcher's "Fusing Machine" equivalent)
│   └── clan-battle-helper.macro      # Este's actual use case; mechanic to be briefed during authoring
└── README.md
```

### First-launch behavior

After the entitlements wizard, macRo copies the seed macros into the user's local library so they have working macros before they've recorded anything. The `auto-grind-biome-1.macro` runs in 60 seconds against a freshly-loaded Pet Sim 99 — that's the wow moment.

### What's specifically Pet-Sim-99 in v1

- Window matchers (just standard Roblox + place ID assertion)
- Default keybindings (canonical PS99 controls — Este records during build)
- The four seed macros above

Everything else (engine, editor, format, distribution) is game-agnostic.

---

## 11. Out of scope, risks, open questions

### Out of scope for v1

- **Subsystem B (factory automation)** — gets its own spec
- **Subsystem C (rich library — browse, rate, fork, comment)** — v1 ships the static-JSON-feed stub
- **Windows / Linux versions** — Mac-native is the moat
- **Mobile** — recording on iPhone is a different problem (no input synthesis APIs)
- **Macro marketplace / payments** — never in scope; macros are free
- **Cloud sync of user macros** — local-first, no auth, no accounts
- **Variables / counters in the schema** (deferred to v2 schema bump)
- **OCR / number reading** (deferred to v2)
- **In-app community features** (comments, ratings) — Subsystem C
- **Game support beyond Pet Sim 99 in-house** — engine is game-agnostic; only PS99 ships with a plugin in v1; community fills the gap from v2 onward
- **Game Plugin Author Kit** (v2/v3)
- **Multi-instance Roblox client management** ("Psycho Manager"-style orchestration of many Roblox accounts) — real customer demand (PH supports up to 100), but Roblox actively discourages multi-instance and v1 should not enter that contested ground. Architecture doesn't preclude adding it in v2/v3 — the engine + plugin loader are per-instance-aware in their abstractions.
- **Discord webhook notifications** (PH ships a `WebHook` mode) — straightforward v2 enhancement: add `notify-discord` as an `action:` on `stopOn` triggers, plus a per-macro `webhookUrl` field. Skipped in v1 because it bumps the surface and forces a "user-supplied secret" flow we'd rather defer.
- **Auction / market sniping macros** (PH's `Market Overlord`, `Market Snipe`) — latency-sensitive single-action automation. Different problem shape than long-running grinds; deserves its own spec section if/when we tackle it.

### Risks

| Risk | Mitigation |
| --- | --- |
| Roblox changes its window class / NSAccessibility surface and breaks every window-targeted macro | `target.windowClass` is an array of fallback matchers, not a single string. macRo also offers "click to identify Roblox window" as user fallback. |
| ScreenCaptureKit permission revoked mid-session | Engine catches the SCK error, pauses run, surfaces clear "permission revoked, fix and resume" UX. Not a crash. |
| Apple Silicon vs Intel CGEvent timing differences | Engine's frame-rate sampling step covers most of it. Add an "input synthesis calibration" CI test that runs on both arches in a VM. |
| Macros recorded at 144Hz play awkwardly at 60Hz (or vice versa) | The 0.5x–2x scaling cap from Section 6 covers this; outside that range, engine warns + offers "re-record at this frame rate" path. |
| Notarization fails right before a release | Notarize-in-CI means we know the moment it breaks. Manual build-and-ship is the documented fallback. |
| Pet Sim 99 introduces an active anti-macro check | Roblox itself doesn't, per Este's read; if a specific game does, we treat it like any other game-specific challenge — adapt the plugin or stop supporting that game. The engine has no anti-detection posture by design. |
| A v1 macro gets shared in the wild and patched-incorrectly by the factory, breaking many users at once | Factory's accuracy-first promise + the multi-candidate eval pipeline. Plus: every published patch carries a one-click "rollback to previous version" in the library panel. |

### Open questions to resolve in implementation, not in this spec

1. **Image-similarity algorithm + thresholds.** Vision template match vs OpenCV ORB vs perceptual hash. A/B during prototype; pick the winner before v1 release.
2. **Roblox FPS detection mechanism.** Auto-detect from SCK frame timestamps first; fall back to user-set value in Settings if drift detected. Both paths exist, auto is default.
3. **Sparkle EdDSA key management.** Generate during first release, store in 1Password, document the recovery flow in `docs/release/`.
4. **Pet Sim 99 canonical keybinding defaults.** Este records during seed-macro authoring.
5. **"What game?" sheet UX.** Search field + dropdown of installed plugins. Defer to UX micro-iteration during build.

---

## 12. References

- **626Labs design system:** `~/projects/626labs-design/` (cloned 2026-05-03 from `github.com/estevanhernandez-stack-ed/626labs-design`)
- **626labs-design skill:** `~/.claude/skills/626labs-design/` (user-invocable)
- **Sanduhr für Claude:** existing 626Labs SwiftUI Mac app, visual precedent for HUD overlays
- **The Architect persona + 626 Labs principles:** `~/.claude/CLAUDE.md`
- **Brainstorm session artifacts:** `.superpowers/brainstorm/13966-1777822898/` (mockups + visual companion screens used during this session)
- **Psycho Hatcher** (`psychohatcher.com`, Discord, `~/Downloads/Psyhco-Hatcher-main/`) — the dominant Windows-only PS99 macro tool. Architecturally similar (per-mode folders, AHK scripts, IMAGES/ for gates), Windows-locked, paid VIP tier. **Used as competitive reference for PS99 feature surface, not as a code source.** Macros and assets are not copied; only their public feature catalog informs which seed macros and v2 candidates we prioritize.

---

## Handoff

This spec is the input to:

1. `/keystone` — bootstrap `CLAUDE.md` for the macRo repo using the 626Labs project-CLAUDE pattern, tenant-aware to macRo's specifics
2. `/vibe-cartographer:scope` — VC reads this doc, runs the rest of its 8-step flow (`/scope` → `/prd` → `/spec` → `/checklist` → `/build` → `/iterate` → `/reflect`)

The `.macro` schema, plugin loader contract, factory hooks, and visual treatment are the load-bearing decisions. Everything downstream is implementation choice.
