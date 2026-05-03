# macRo — Technical Spec

> **Spec-first cycle (Substrate (mm) pattern).** The full architectural design lives at [`docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`](superpowers/specs/2026-05-03-macro-mac-app-design.md) (the design spec). This `docs/spec.md` is the Cart-flow technical-spec artifact: it preserves the section structure `/checklist` consumes, captures the **Deployment — Identity & Signing** contract, cross-references PRD epics, and pointer-stubs the rest. When this spec is silent on a behavior, the design spec is authoritative.

## Stack

- **Mac app (v1):** Swift 5.9+, SwiftUI, native Apple SDKs only.
  - [`ScreenCaptureKit`](https://developer.apple.com/documentation/screencapturekit) (capture)
  - [`Quartz Event Services`](https://developer.apple.com/documentation/coregraphics/quartz_event_services) — `CGEventTap` + `CGEvent.post` (input record + synthesis)
  - [`AVFoundation`](https://developer.apple.com/documentation/avfoundation) — `AVAssetWriter` for encoding
  - [`NSWorkspace`](https://developer.apple.com/documentation/appkit/nsworkspace) + [`AXUIElement`](https://developer.apple.com/documentation/applicationservices/axuielement) (window + accessibility detection)
  - [`Sparkle 2.x`](https://sparkle-project.org) (auto-update, EdDSA signatures)
- **Factory pipeline (Subsystem B, later cycle):** TypeScript + [Bun](https://bun.sh). Empty path reserved at `tools/factory/` in v1.
- **Schema codegen:** Single source of truth at `schema/macro.schema.yaml`. Swift `MacroFormat` + TS schema types both generated from it (tool TBD in /build — Quicktype, hand-written codegen, or Swift macros).

Rationale: Mac-native is the spec's load-bearing moat (design spec § 1, § 3). The architecture choice was made and locked during brainstorm; this spec carries it forward.

## Runtime & Deployment

- **macOS 14+ (Sonoma)** — required for ScreenCaptureKit's modern API.
- **Both Apple Silicon and Intel** — Universal binary.
- **Permissions:** Accessibility + Screen Recording. Both required; first-launch wizard handles the grants (PRD epic A).
- **Distribution:** GitHub Releases, signed + notarized DMG. Sparkle 2.x for auto-update.

### Deployment — Identity & Signing

Per the SKILL's GitHub Releases row + the macRo-specific Apple bits.

| Field | Value |
| --- | --- |
| Repo slug | `estevanhernandez-stack-ed/Macro` |
| Release tag scheme | `v<MAJOR>.<MINOR>.<PATCH>` (semver). `v0.x.y` until v1 launch. |
| Signing identity | Apple Developer ID (Estevan's Apple Developer Program account; TBD at first release) |
| Notarization | `xcrun notarytool` via GitHub Actions; staple post-notarization |
| Sparkle EdDSA private key | Stored in 1Password under `macRo / Sparkle Private Key`. Public key embedded in app bundle. Recovery flow: regenerating breaks all existing client updates — document the recovery break protocol when key is generated. |
| Appcast hosting | `https://626labs.github.io/macRo/appcast.xml` (GitHub Pages branch of this repo) |
| Release asset path | `dist/macRo-v<version>.dmg` |
| `GITHUB_TOKEN` scope | `contents: write` (release-create + asset-upload). Provided automatically by GitHub Actions. |
| GitHub-hosted secrets needed | `APPLE_ID` (Apple ID email), `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (app-specific password), `SPARKLE_PRIVATE_KEY` (ed25519 armored), `MACOS_CERTIFICATE` (base64 .p12), `MACOS_CERTIFICATE_PWD` |
| CI workflow | `.github/workflows/release.yml`, triggers on `push` of tags matching `v*` |
| Pre-release behavior | Marking a GitHub Release as "pre-release" causes Sparkle to skip it for stable-channel users (PRD epic F). |

`/checklist` consumes this section directly for release-related items.

## Architecture Overview

Three subsystems, sharing only the `.macro` bundle format as a contract. Subsystem A (Mac app) ships in v1; B and C are deferred specs.

```
                        ┌─────────────────────────────────────────────┐
                        │  Subsystem A — Mac app (v1, Swift/SwiftUI)  │
                        │                                             │
                        │  UI ────► Domain ────► Native services ────►│ macOS
                        │   ▲          ▲              (SCK, CGEvent,  │
                        │   │          │               AVFoundation,  │
                        │   └──────────┴── MacroFormat (schema mod)   │
                        │                                             │
                        └──────────────┬──────────────────────────────┘
                                       │ reads/writes
                                       ▼
                              ┌──────────────────┐
                              │  .macro bundles  │  ← shared contract
                              │  (folder format) │
                              └──────────────────┘
                                       ▲
                          ┌────────────┼────────────┐
                          │ writes     │            │ reads
                          │ (later)    │            │ (later)
                          ▼                         ▼
                ┌──────────────────┐      ┌──────────────────┐
                │ Subsystem B —    │      │ Subsystem C —    │
                │ Factory pipeline │      │ Library          │
                │ (TS/Bun, later)  │      │ (later)          │
                └──────────────────┘      └──────────────────┘
```

Detail: design spec § 3 (Mac app architecture), § 5 (capture → edit), § 6 (playback engine), § 7 (distribution + factory hooks), § 9 (plugin model).

## Components (heading addresses for /checklist)

Each subcomponent below has a corresponding section in the design spec; bodies are pointer-stubbed.

### Native services layer (Swift)

Implements the bottom of design spec § 3. PRD refs: epic B (Recording), epic D (Playback).

#### ScreenCaptureKit wrapper
Capture session driver. Output goes to a dedicated `SCStreamOutput` delegate; never closures-capturing-self. Window content rect only (not whole screen, not the HUD).

#### CGEventTap + CGEvent.post wrapper
Input record + synthesis. Tap allocated with annotated-session options, enabled with `CGEvent.tapEnable`, invalidated on stop. Synthesis uses `.cghidEventTap` for system-realistic event injection.

#### AVFoundation encoder
`AVAssetWriter`-based recording-video encoder. Precise timing control (no `AVCaptureMovieFileOutput`).

#### NSAccessibility / NSWorkspace window detection
`AXUIElementCreateApplication` + traversal for window matching. Bundle-ID matching alone is insufficient (Roblox spawns child windows). PRD ref: epic D pre-flight.

### Domain layer (Swift, no UI imports)

Implements the middle of design spec § 3. PRD refs: epics B, C, D, E.

#### `Recorder`
Drives the capture session, owns the recording timeline, writes raw artifacts to a working directory. PRD ref: epic B.

#### `MacroBundle`
Load/save the `.macro` folder, schema validation, versioning. PRD ref: epic C save flow.

#### `Engine`
Playback runtime. Reads `MacroBundle`, drives gates + input synthesis, frame-rate-aware timing, abort handling, schedule honoring, stopOn polling. PRD ref: epic D.

#### `LibraryStore`
Local macro inventory + (stubbed) remote feed. Reads from `~/Library/Application Support/macRo/Library/<game>/*.macro` plus the configurable remote JSON feed. PRD ref: epic E.

#### `Permissions`
Requests + checks Accessibility + Screen Recording entitlements. Drives the first-launch wizard. PRD ref: epic A.

#### `PluginLoader`
Indexes game plugins from three locations (app-bundled, user-installed, URL-installable). Surfaces them in the "What game?" sheet. PRD ref: epic B (game-pick) + epic D (window matching).

### UI layer (SwiftUI)

Implements the top of design spec § 3. PRD refs: all epics A–E.

#### `OnboardingView`
First-launch wizard: welcome → entitlements wizard → done. PRD ref: epic A.

#### `RecorderHUD`
Draggable overlay during recording. Timer, abort, hotkey hint. Position remembered across sessions. PRD ref: epic B.

#### `EditorView`
The iMovie-flavored timeline editor. Four lanes (VIDEO / MOVE / ACTIONS / GATES), inspector panel, toolbar (subs / stopOn / schedule), script-view toggle. PRD ref: epic C. Visual reference: locked v2 mockup at `.superpowers/brainstorm/13966-1777822898/content/editor-shape-v2.html` (gitignored, local).

#### `LibraryView`
Browse local + remote macros. Install / update / rollback / delete. PRD ref: epic E.

#### `RunHUD`
Minimal playback overlay: countdown, stop button, current-state indicator (running / gating / paused). PRD ref: epic D.

### Cross-cutting modules

#### `MacroFormat`
Separate Swift module containing only the bundle schema types. Zero UI deps, zero domain deps. Generated from `schema/macro.schema.yaml`. Both domain and UI depend on it; nothing depends on the UI layer. This is the lockstep contract with Subsystem B (TS schema types are also generated from the same schema). Detail: design spec § 3 cross-cutting + § 4 schema source of truth.

#### `MacRoTheme`
SwiftUI theme that maps 626Labs design tokens to SwiftUI types (`Color`, `Font`, `EdgeInsets`, `RoundedRectangle` radii). Every SwiftUI view in macRo reaches through `MacRoTheme` — no hardcoded `.foregroundColor(.blue)` or `.font(.body)`. Token source: `~/projects/626labs-design/colors_and_type.css` (consult via the `626labs-design` skill). Detail: design spec § 8.

### `.macro` bundle format

Folder-as-file (Mac idiom via `LSItemContentTypes`). Contents: `manifest.yaml`, `timeline.yaml`, `gates/*.png`, optional `preview.mp4`. Detail: design spec § 4.

### Schema source of truth

- **File:** `schema/macro.schema.yaml`
- **Codegen output:** Swift `MacroFormat` types (consumed by domain + UI) + TS schema types (consumed by Subsystem B later). Generation tool TBD in /build (Quicktype / hand-written / Swift macros).
- **CI guard:** Lockstep — any change to the schema MUST regenerate both type sets in the same commit. CI fails if types drift.
- **v1 schema fields:** stop conditions, schedule windows, sub-macros + branches, window targeting, resolution policy, game version pin + required bindings, gates (POS + IMG), `factoryPatchable`, `patchHistory`. Detail: design spec § 4.
- **v2 deferred:** variables / counters, OCR, sound resources, macro composition. Detail: design spec § 4 deferred.

### Factory hooks (present in v1)

Detail: design spec § 7 factory hooks. The schema source-of-truth, the bundle naming convention (`<game-slug>/<macro-id>.macro`), the `factoryPatchable` opt-in, the `versionFingerprint` field, the reserved `tools/factory/` path, and the `patchHistory` audit trail are all present in v1 so Subsystem B drops in without retrofitting.

### PS99 plugin (`games/pet-sim-99/`)

- `plugin.yaml` — placeId, displayName, window matchers, default bindings
- `seed-macros/` — `auto-hatch.macro`, `auto-grind-biome-1.macro`, `auto-rebirth.macro`, `auto-fuse-pets.macro`, `clan-battle-helper.macro`
- `README.md` — what's PS99-specific, why

PRD ref: epic A first-launch seed install. Detail: design spec § 10.

### Distribution & release

- `tools/release/notarize.sh` — local notarization wrapper
- `.github/workflows/release.yml` — CI workflow on `v*` tag push
- `tools/release/generate-appcast.sh` — appcast.xml generator from release feed
- `appcast.xml` hosted on GitHub Pages branch

PRD ref: epic F. Detail: design spec § 7 distribution.

## Data Model

The macro file format. Detail: design spec § 4.

### `manifest.yaml`
Required: `id`, `name`, `schemaVersion`, `version`, `factoryPatchable`. Optional but standard: `game.placeId` + `game.name` + `game.versionFingerprint`, `target.windowClass[]` + `target.windowTitleMatch` + `target.coordinateSpace` + `target.recordedResolution` + `target.resolutionPolicy`, `requires.bindings[]`, `schedule[]`, `patchHistory[]`, `estimatedRuntime`, `recordedFrameRate`, `maxRuntimeHours`.

### `timeline.yaml`
`events[]` — each with `t` (number) + `kind` + kind-specific fields. Kinds: `keyDown`, `keyUp`, `keyPress`, `click`, `cameraDelta`, `gate`, `loop`, `invokeSub`. Plus top-level `stopOn[]`, `subs{}`.

### `gates/`
PNG snapshots. Naming convention: `<gateKind>-<descriptive-slug>.png` (e.g., `img-catch-prompt.png`, `pos-fishing-spot.png`).

## File Structure

```
macRo/                              # repo root
├── README.md                       # public intro, links to spec
├── CLAUDE.md                       # how-to-work-here for agents
├── .gitignore                      # macOS, Xcode, SwiftPM, .superpowers/, .claude/settings.local.json
├── process-notes.md                # cycle-by-cycle process log
├── docs/
│   ├── builder-profile.md          # /onboard artifact
│   ├── scope.md                    # /scope artifact (pointer-stub)
│   ├── prd.md                      # /prd artifact (six epics, stories+ACs)
│   ├── spec.md                     # this file
│   ├── checklist.md                # /checklist artifact (pending)
│   ├── reflection.md               # /reflect artifact (pending)
│   └── superpowers/
│       └── specs/
│           └── 2026-05-03-macro-mac-app-design.md   # the load-bearing design spec
├── .claude/
│   ├── settings.local.json         # gitignored
│   ├── agents/
│   │   ├── swift-mac-app-reviewer.md           # production
│   │   ├── macro-bundle-validator.md           # production
│   │   ├── design-system-applier.md            # stub
│   │   ├── spec-vs-implementation-reviewer.md  # stub
│   │   └── bun-factory-builder.md              # stub
│   ├── rules/
│   │   ├── swift-conventions.md                # stub
│   │   ├── macro-format-rules.md               # stub
│   │   └── release-process.md                  # stub
│   └── hooks/
│       └── README.md                            # stub (codegen hook + secret-scan hook planned)
├── schema/
│   └── macro.schema.yaml           # single source of truth (codegen input)
├── App/                            # planned — Swift/SwiftUI app source
│   ├── macRo.xcodeproj/
│   ├── macRo/
│   │   ├── Native/                 # ScreenCaptureKit, CGEventTap, AVFoundation wrappers
│   │   ├── Domain/                 # Recorder, MacroBundle, Engine, LibraryStore, Permissions, PluginLoader
│   │   ├── UI/                     # OnboardingView, RecorderHUD, EditorView, LibraryView, RunHUD
│   │   ├── Theme/                  # MacRoTheme + 626Labs token mappings
│   │   ├── Schema/                 # MacroFormat (codegen output)
│   │   ├── App.swift               # @main entry, Sparkle setup, abort hotkey registration
│   │   └── Info.plist              # LSItemContentTypes for .macro bundle, entitlements declarations
│   ├── macRoTests/
│   └── Package.swift               # if SPM-based
├── games/
│   └── pet-sim-99/
│       ├── plugin.yaml
│       ├── seed-macros/
│       │   ├── auto-hatch.macro/
│       │   ├── auto-grind-biome-1.macro/
│       │   ├── auto-rebirth.macro/
│       │   ├── auto-fuse-pets.macro/
│       │   └── clan-battle-helper.macro/
│       └── README.md
├── tools/
│   ├── factory/                    # planned — Subsystem B (Bun project, empty in v1 except README)
│   │   └── README.md
│   ├── release/
│   │   ├── notarize.sh             # local notarization wrapper
│   │   └── generate-appcast.sh
│   └── codegen/
│       └── generate-types.ts       # or similar — schema → Swift + TS types
├── .github/
│   └── workflows/
│       ├── ci.yml                  # build + test on PRs
│       └── release.yml             # notarize-in-CI on v* tags
└── appcast.xml                     # generated, pushed to gh-pages branch
```

## Key Technical Decisions

The design spec is the durable storage for decision rationale. These three are the load-bearing ones for /checklist sequencing:

1. **Schema codegen-first.** Implementing the codegen pipeline before any domain or UI code means every Swift file that touches macros uses generated types from day one. Cost: extra setup time before "first runnable Swift code." Benefit: zero schema drift across the cycle, and Subsystem B can ship without retrofitting.
2. **Engine before editor.** Implement playback engine + run-loop semantics before the editor UX. Reason: the editor's "Run this macro" button needs the engine to exist and be testable. Editor with no working engine is empty UI. Engine without an editor can be tested via hand-authored YAML bundles.
3. **PS99 plugin authored last.** Engine + format must be game-agnostic. Authoring the PS99 plugin first risks tight-coupling. Build the engine against synthetic / hand-authored bundles; author PS99 seeds at the end of the cycle when the engine is proven.

## Dependencies & External Services

| Dependency | Purpose | Docs |
| --- | --- | --- |
| Sparkle 2.x | Auto-update | https://sparkle-project.org |
| ScreenCaptureKit | Capture | https://developer.apple.com/documentation/screencapturekit |
| Quartz Event Services | Input record/synth | https://developer.apple.com/documentation/coregraphics/quartz_event_services |
| AVFoundation | Encode/decode | https://developer.apple.com/documentation/avfoundation |
| Apple Developer Program | Code signing + notarization | https://developer.apple.com/programs/ |
| GitHub Releases + Pages | Distribution + appcast hosting | https://docs.github.com/en/repositories/releasing-projects-on-github |
| Bun (Subsystem B, later) | TS runtime for factory | https://bun.sh |
| 626Labs design system | UI tokens | `~/projects/626labs-design/`, `~/.claude/skills/626labs-design/` |

No external services that require API keys / pricing / rate-limit consideration in v1. Everything is local-first.

## Open Issues

Carrying forward from PRD § Open Questions, plus architecture-self-review findings:

- **Image-similarity algorithm + thresholds** — pick during prototype, before v1 release. /checklist will create an A/B harness as one of the early items.
- **Codegen tool choice** (Quicktype / hand-written / Swift macros) — pick at first schema-codegen build item.
- **Sparkle EdDSA key generation timing** — generate at first release tag; document recovery.
- **PS99 canonical keybinding defaults** — Estevan records during seed-macro authoring (/build-time clarification, not a /spec blocker).
- **Clan-battle macro mechanic** — Estevan to brief during the seed-macro authoring item.
- **`MacRoTheme` token mapping precision** — invoke `626labs-design` skill at first SwiftUI authoring beat; let it produce the mapping.
- **Self-review finding 1:** the design spec lists `requires.bindings` validation as a pre-flight check, but doesn't specify what happens if the user can't (or won't) confirm the binding match. /checklist should add a UX item: "binding-mismatch UX" (modal? blocking? skip-able? remember-per-macro?).
- **Self-review finding 2:** the spec's "Engine never synthesizes input outside the target window's content rect" is a hard rule, but the v1 schema has resolution-scaling that can produce coords slightly outside the rect after scaling. /checklist should add a clamping-step item to verify scaled coords are clamped before synthesis.
- **Self-review finding 3:** the auto-update flow for `factoryPatchable: true` macros polls feed at launch — but if the user has manually edited a factory-patchable macro since install, the PRD AC says "warn" but the spec doesn't define HOW edits are detected. /checklist should add an item: "store original-bundle hash at install time; compare against current state before auto-updating."

These three architecture-self-review findings are the kind of edge cases the SKILL flags as the deepening-round payoff, even in autonomous mode.
