# macRo

The Mac macro maker for Roblox. Native Swift / SwiftUI; one-click record, edit, replay; HUD overlays; per-game plugin packs; signed + notarized + Sparkle-updated.

> _Imagine Something Else._

[![Latest Release](https://img.shields.io/github/v/release/estevanhernandez-stack-ed/Macro)](https://github.com/estevanhernandez-stack-ed/Macro/releases/latest) [![License](https://img.shields.io/github/license/estevanhernandez-stack-ed/Macro)](LICENSE)

---

## What it does

Three subsystems, one contract — the `.macro` bundle format:

- **Record** — capture gameplay (synced video + input event stream + per-action snapshots).
- **Edit** — iMovie-flavored 4-lane timeline (VIDEO / MOVE / ACTIONS / GATES).
- **Replay** — frame-rate-aware engine with safety gates and a global abort hotkey (`⌃⌥⌘.`).

Pet Simulator 99 ships as the v1 plugin; community plugins land via `plugin.yaml` from v2.

[insert screenshot: OnboardingView]

---

## Install

> Pre-release — the first signed + notarized DMG ships at `v0.1.0`. Until then, build from source (see [Develop](#develop)) or grab a CI artifact from the [Actions tab](https://github.com/estevanhernandez-stack-ed/Macro/actions).

Once `v0.1.0` lands:

1. Download the latest DMG from the [Releases page](https://github.com/estevanhernandez-stack-ed/Macro/releases/latest).
2. Drag `macRo.app` to `/Applications/`.
3. Launch. Walk the onboarding wizard — grant Accessibility + Screen Recording.
4. Five PS99 seed macros appear in your Library tagged "Pet Simulator 99". Hit Run.

System requirements: macOS 14 Sonoma or newer.

---

## Tech stack

- **Mac app:** Swift / SwiftUI. Native Apple APIs only — ScreenCaptureKit, CGEventTap, AVFoundation, NSAccessibility. macOS 14+ deployment target.
- **Schema:** YAML (`schema/macro.schema.yaml`) is the single source of truth for the `.macro` bundle format. Swift `MacroFormat` types codegen from it (`bun run codegen`).
- **Updates:** Sparkle 2.x (pinned 2.9.1), EdDSA-signed appcast hosted on GitHub Pages.
- **Distribution:** Apple Developer ID signed + notarized DMG; GitHub Releases + Sparkle.
- **Build:** Xcode 16.x, XcodeGen for project generation. CI on `macos-14` (GitHub Actions).
- **Tests:** XCTest. 64+ tests covering schema, IO, engine, recorder, editor, library, plugin loader, Sparkle integration.
- **Dependencies:** Yams 5.4.0 (YAML parsing), Sparkle 2.9.1 (auto-update). Both via SPM.

[insert screenshot: EditorView with the 4 lanes]

---

## Screenshots

[insert screenshot: OnboardingView]
[insert screenshot: RecorderHUD over Roblox]
[insert screenshot: EditorView 4-lane timeline]
[insert screenshot: LibraryView card grid]

> Screenshots placeholder — captured during the empirical PS99 verification pass.

---

## Develop

```bash
git clone git@github.com:estevanhernandez-stack-ed/Macro.git
cd Macro/App
xcodegen generate
xed macRo.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project App/macRo.xcodeproj -scheme macRo build
xcodebuild -project App/macRo.xcodeproj -scheme macRo test -destination 'platform=macOS,arch=x86_64'
```

The `.macro` schema lives at [`schema/macro.schema.yaml`](schema/macro.schema.yaml). Regenerate Swift types via `bun run codegen` from the repo root (requires [Bun](https://bun.sh)).

For the release pipeline + bootstrap docs: [`tools/release/README.md`](tools/release/README.md).

---

## Documentation

- **Design spec:** [`docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`](docs/superpowers/specs/2026-05-03-macro-mac-app-design.md) — load-bearing source of truth for what we're building.
- **PRD:** [`docs/prd.md`](docs/prd.md)
- **Tech spec:** [`docs/spec.md`](docs/spec.md)
- **Build checklist:** [`docs/checklist.md`](docs/checklist.md)
- **Working conventions:** [`CLAUDE.md`](CLAUDE.md)
- **626Labs design system:** canonical brand spec, used across every 626Labs product.

---

## Project posture

- **No telemetry, ever.** Anonymous GitHub release download counts are the only signal we collect — and we don't even own them; GitHub does.
- **No anti-detection logic.** macRo records and replays. If a game introduces an active anti-macro check, we adapt the plugin or stop supporting that game.
- **No Electron retrofit.** macOS-native is the moat.
- **`factoryPatchable: true` is sacred.** Macros marked `factoryPatchable: false` are never touched by the factory pipeline (Subsystem B).

---

## License

License TBD.

---

Built by [Estevan Hernandez](https://github.com/estevanhernandez-stack-ed). Part of the [626Labs](https://626labs.com) family of products.
