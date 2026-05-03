# macRo — Product Requirements

> **Spec-first cycle (Substrate (mm) pattern).** This PRD is the stories + ACs + prioritization layer over the architectural design at [`docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`](superpowers/specs/2026-05-03-macro-mac-app-design.md). When this PRD is silent on a behavior, the spec is authoritative.

## Problem Statement

The Roblox player who knows what macros do, has used other people's, and has never been able to author one from scratch is stuck on Windows-only tools (Psycho Hatcher, AHK community scripts) — or, when they're on a Mac, has no real option at all. Authoring is script-first ("write your own .ahk") or record-and-pray (no editor, no gates, breaks the moment any UI element moves). They open Pet Simulator 99 every day. They want their own clan-battle helper, their own auto-hatch tuned to their loadout — not someone else's.

## Personas

- **The Player** (primary v1 user) — Mac PS99 player, knows what macros do, never authored one. Lives in the timeline editor; never sees YAML.
- **The Power User** (small subset of The Player) — wants the script view to refine timing or chain conditionals. Comfortable reading YAML.
- **The Author** (v2+ persona, named so v1 seams stay clean) — community plugin author. Knows their game; wants to plug in a new game without waiting for 626Labs. The Game Plugin Author Kit lands v2/v3.
- **Estevan** (release operator) — ships releases via tag pushes; reads logs; tunes seed macros.

## User Stories

### Epic A — Onboarding & permissions

- As **The Player**, when I launch macRo for the first time, I see a welcome screen that explains what macRo does and what permissions it needs.
  - [ ] Welcome shows: macRo name, tagline, one-line "what this is" description, and a single Continue button.
  - [ ] No app behavior is triggered until I click Continue (no preference files written, no permissions requested).
  - [ ] Quitting from the welcome screen leaves no residue on disk other than `~/Library/Application Support/macRo/` being created if it didn't exist.

- As **The Player**, I'm walked through granting Accessibility + Screen Recording permissions, in plain English, with deep-links into System Settings if I deny one.
  - [ ] Each permission shows: human name, plain-English reason, real-time status (granted / denied / not-asked), and a button that either triggers the system prompt or deep-links to the relevant System Settings pane.
  - [ ] App refuses to proceed past the wizard until both permissions are granted.
  - [ ] If I grant permissions, then revoke them via System Settings later, the app returns to the wizard on next foreground.
  - [ ] *Edge case:* if Screen Recording is granted but Accessibility is denied, the wizard explains which features won't work and offers to wait or quit.

- As **The Player**, after permissions are granted, I land on the Library view with the PS99 seed macros already installed.
  - [ ] Library shows ≥4 PS99 seed macros within 1 second of the wizard completing.
  - [ ] Each seed macro card shows: name, game, version, "Run" button, "..." menu (rename, delete, view in Finder, view as YAML).
  - [ ] Clicking Run on `auto-grind-biome-1.macro` against a freshly-loaded PS99 produces visible play within 60 seconds (the wow moment).

### Epic B — Recording

- As **The Player**, I can start a new recording from the Library and pick which game I'm recording for.
  - [ ] "New Recording" button opens a "What game?" sheet.
  - [ ] Sheet shows: installed plugins (PS99 default-selected), "Untagged / general" option.
  - [ ] Picking a game pre-fills `target.windowTitleMatch`, `target.windowClass`, and `target.recordedResolution` from the plugin's `plugin.yaml` and the current Roblox window.

- As **The Player**, when I confirm "Start", I get a 3-2-1 countdown to refocus the Roblox window.
  - [ ] Countdown is large, centered, dismissable with Escape.
  - [ ] *Edge case:* if Roblox isn't frontmost when the countdown ends, recording auto-pauses and shows "bring Roblox to the front to continue" until I do.
  - [ ] *Edge case:* if Roblox crashes or quits mid-countdown, the recording cancels with a clear message.

- As **The Player**, while recording, the RecorderHUD overlays the screen with the current duration, an Abort button, and the global hotkey hint.
  - [ ] HUD shows MM:SS timer ticking once per second.
  - [ ] HUD has a Stop button and a one-line hint: `⌃⌥⌘. to abort`.
  - [ ] HUD is draggable; remembers position across sessions.
  - [ ] HUD's own clicks never appear in the recorded input log.
  - [ ] *Edge case:* if I drag the HUD over the Roblox window, the engine does NOT capture HUD-position clicks as game inputs.

- As **The Player**, every keystroke, mouse click, and camera movement I make in the Roblox window is captured for the macro.
  - [ ] All keyDown / keyUp / click / cameraDelta events written to `raw-input.jsonl` with monotonic timestamps.
  - [ ] Coordinates stored window-relative (not screen-relative).
  - [ ] Frame snapshots written to `snapshots/` at every input event AND every 1 second.
  - [ ] *Edge case:* if I switch windows mid-recording, the recorder pauses input capture (but keeps the video) until I'm back.

- As **The Player**, when I stop recording, EditorView opens with my recording loaded into the timeline.
  - [ ] Stop closes the HUD, finalizes the working dir, opens EditorView in <2 seconds.
  - [ ] All four lanes (VIDEO / MOVE / ACTIONS / GATES) populate from the captured streams. GATES starts empty.
  - [ ] Video preview shows the first frame; transport is at 0:00.

### Epic C — Editing

- As **The Player**, I can scrub the timeline by clicking, dragging, or using arrow keys.
  - [ ] Clicking on the VIDEO lane jumps the playhead to that timestamp.
  - [ ] Spacebar toggles play / pause.
  - [ ] Left / right arrow nudge the playhead by 1 frame; shift-arrow nudges by 1 second.

- As **The Player**, I can drag the edges of a kept segment to trim, or click between segments to add a cut.
  - [ ] Trimming a kept segment shrinks the timeline (the cut range is removed entirely from the macro, not muted).
  - [ ] Adding a cut splits a kept segment into two kept segments with a gap between them.
  - [ ] Cuts can NOT be added inside an existing gate event (the gate must be removed first; UI surfaces this).
  - [ ] ⌘Z / ⌘⇧Z undo / redo all edit operations.

- As **The Player**, I can click an input event in MOVE or ACTIONS to refine it.
  - [ ] Clicking opens an inspector panel on the right.
  - [ ] Inspector lets me: edit timing offset (±100ms), swap "click at x,y" for "click on image-of-target" (image-anchored), add jitter (±X ms randomization), delete the event.
  - [ ] Changes are reflected immediately in the underlying YAML model.
  - [ ] *Edge case:* deleting a MOVE event that was a `keyDown` automatically deletes its paired `keyUp` (or shows a warning if the pair is past a cut).

- As **The Player**, I can drop an image-trigger gate at any timestamp.
  - [ ] "+ Image trigger" button opens a frame-cropper showing the snapshot at the current timestamp.
  - [ ] Cropped image saves as `gates/img-<id>.png` and inserts a `gate` event at that time.
  - [ ] Default values: `retries: 3`, `timeout: 30s`, `onFail: continue`.
  - [ ] *Edge case:* if no snapshot exists at the current timestamp (rare; happens when scrubbing between snapshots), nearest snapshot is used and a warning is shown.

- As **The Player**, I can drop a position-trigger gate the same way I drop an image trigger.
  - [ ] "+ Position trigger" button opens the same cropper but tags the result as a position cue (different `gateKind: pos`).
  - [ ] Engine treats POS gates with looser similarity threshold than IMG gates.
  - [ ] Default values: `retries: 3`, `timeout: 30s`, `onFail: abort` (position failures are usually critical).

- As **The Power User**, I can toggle to a YAML script view to edit `manifest.yaml` and `timeline.yaml` directly.
  - [ ] Toolbar toggle opens a split-pane editor (timeline left, YAML right) or a full-screen YAML editor (configurable).
  - [ ] Schema validation runs live; invalid YAML highlights inline.
  - [ ] Round-trips losslessly: timeline → YAML → timeline doesn't drift.
  - [ ] *Edge case:* an invalid YAML state blocks Save and shows a "fix the highlighted errors first" banner.

- As **The Player**, when I save my macro, it lands as a `.macro` bundle in my library.
  - [ ] Save packages the working dir into the final bundle: `manifest.yaml` + `timeline.yaml` + `gates/*.png`. Drops uncut video frames from `snapshots/`, keeps only gate-referenced ones.
  - [ ] Default save location: `~/Library/Application Support/macRo/Library/<game-slug>/<macro-id>.macro`.
  - [ ] Library panel updates immediately with the new macro card.
  - [ ] *Edge case:* if the macro id collides with an existing macro, save prompts: "Replace, save as new version, or cancel?"

### Epic D — Playback

- As **The Player**, I can run any macro from the Library and the engine will execute it safely.
  - [ ] Pre-flight runs silently: schema-version check, window-match (with 10s wait), required-bindings prompt (once per macro), schedule check, FPS sample (~1s), resolution-scale calc.
  - [ ] On any pre-flight failure, engine aborts with a clear message and never starts synthesis.
  - [ ] *Edge case:* if pre-flight succeeds but Roblox loses focus during the FPS sample, engine pauses pre-flight, prompts to refocus, retries.

- As **The Player**, I can stop a running macro at ANY time using the global abort hotkey.
  - [ ] `⌃⌥⌘.` (Control+Option+Command+Period) aborts the macro within 200ms regardless of which app has focus.
  - [ ] RunHUD stop button does the same.
  - [ ] *Hard rule:* the abort hotkey is registered as an `NSEventMonitor` at app launch and remains registered for the entire app lifetime — no engine state can deregister it.

- As **The Player**, image gates and position gates are honored — the macro pauses until the right thing is on screen.
  - [ ] IMG gates use ~95% template-match similarity threshold (final algorithm picked during prototype phase).
  - [ ] POS gates use ~85% threshold (looser; environment lighting varies).
  - [ ] On `gate.retries` consecutive failures, engine takes the `onFail` action (`abort` / `continue` / `sub:<name>`).
  - [ ] *Edge case:* if a gate's reference image was generated from a different resolution than the current playback resolution, engine warns and applies resolution-scaling to the comparison.

- As **The Player**, the engine respects schedule windows in the macro's manifest.
  - [ ] If schedule says 22:00–06:00 and current time is 14:00, engine enters paused state, no input synthesized.
  - [ ] When current time enters the window, engine resumes automatically.
  - [ ] User can override with a "Run anyway" button on the RunHUD.
  - [ ] *Edge case:* if I cross a daylight-savings transition mid-run, the schedule window slides accordingly (timezone is interpreted strictly per the manifest).

- As **The Player**, stop conditions interrupt a running macro the moment they fire.
  - [ ] `stopOn` triggers polled every 500ms in parallel with the run loop.
  - [ ] `action: pause` shows a Mac notification and freezes the engine.
  - [ ] `action: exit` cleanly stops.
  - [ ] `action: sub:<name>` runs the named sub-macro then resumes main.
  - [ ] *Edge case:* if a stop condition fires while a gate is currently retrying, the stop wins (gate is abandoned).

- As **The Player**, the engine NEVER synthesizes input outside the Roblox window's content rect or while macRo is frontmost.
  - [ ] Coordinate translation clamps every click to the current Roblox window content rect.
  - [ ] Engine asserts `NSWorkspace.frontmostApplication` is Roblox before each synthesis call.
  - [ ] If Roblox loses focus mid-run, engine pauses (not aborts) and shows "bring Roblox back to resume."
  - [ ] All synthesis events log to `~/Library/Application Support/macRo/Logs/<run-id>.log` (local only, never sent anywhere).

### Epic E — Library

- As **The Player**, the Library shows local macros AND macros from a remote feed.
  - [ ] Library reads `~/Library/Application Support/macRo/Library/<game>/*.macro` for local.
  - [ ] Library reads the remote feed at `https://macros.626labs.com/feed.json` (URL configurable in Settings).
  - [ ] Each macro shows: name, game, version, source (local / remote), last updated, factoryPatchable status.
  - [ ] *Edge case:* if the remote feed is unreachable, Library still shows local-only with a "feed unavailable" note (no error modal).

- As **The Player**, I can install a macro from the remote feed in one click.
  - [ ] Click "Install" → app downloads the bundle ZIP → verifies SHA-256 against the feed's claim → unzips into local Library.
  - [ ] Failures surface clear, actionable errors: "no network" / "hash mismatch (likely tampered)" / "disk full" / etc.
  - [ ] Installed macros appear in the local section immediately.

- As **The Player**, factory-patched macros auto-update on next app launch.
  - [ ] App polls feed at launch (silently; no progress modal).
  - [ ] If a `factoryPatchable: true` macro has a newer version, prompt: "Update <name> to v1.2? (rollback available if it breaks)".
  - [ ] User can disable auto-update prompt per-macro from the macro's "..." menu.
  - [ ] *Edge case:* if the user has manually edited a `factoryPatchable: true` macro since install, app warns: "your local edits will be overwritten — keep yours, install update, or save yours as a new macro?"

- As **The Player**, I can roll back to a prior version of a factory-patched macro.
  - [ ] App stores last 3 versions of each factory-patched macro in `~/Library/Application Support/macRo/Library/.versions/`.
  - [ ] Macro card has "Rollback to v1.1" entry in the "..." menu.
  - [ ] Rollback is instant (just swaps which version is active in the library directory).

- As **The Player**, I can delete a macro from my library.
  - [ ] Right-click → Delete → confirmation modal.
  - [ ] Deletion removes the bundle AND its rollback versions.
  - [ ] If the deleted macro was a remote install, "Install" appears again in the feed view.

### Epic F — Distribution & release

- As **Estevan**, I can ship a release by tagging `v0.1.0` and pushing the tag.
  - [ ] GitHub Actions notarize-in-CI workflow fires on `v*` tag pushes.
  - [ ] Workflow: build → sign with Apple Developer ID → notarize via `xcrun notarytool` → staple → attach DMG to the GitHub Release.
  - [ ] Sparkle `appcast.xml` regenerates and pushes to the GitHub Pages branch automatically.
  - [ ] Workflow fails loudly (red CI) if any step breaks; no silent failures.

- As **The Player**, when an app update is available, Sparkle prompts me on next launch.
  - [ ] Sparkle reads `appcast.xml` from `https://626labs.github.io/macRo/appcast.xml` (or wherever GitHub Pages hosts).
  - [ ] Update prompt is non-blocking: I can install now, defer, or skip this version.
  - [ ] Updates are EdDSA-signed; if a signature fails, Sparkle silently refuses without prompting.
  - [ ] *Edge case:* if I skip a version, future updates from that version forward are still offered.

- As **Estevan**, if a release breaks users, I can roll back fast.
  - [ ] Marking a GitHub Release as "pre-release" causes Sparkle to skip it for stable-channel users.
  - [ ] Publishing a hotfix `v0.1.1` after a broken `v0.1.0` reaches all users on next-launch poll.
  - [ ] Released DMGs are NEVER deleted from GitHub Releases (Sparkle clients may already have downloaded them).

## What we're building (v1)

The acceptance-criteria list above is the v1 must-have set. Specifically:
- All of Epic A (onboarding + permissions + first-launch seed macros)
- All of Epic B (recording flow with HUD, parallel streams, draft handoff)
- All of Epic C (editing: scrub, cut, refine, gate-drop, script view, save)
- All of Epic D (playback: pre-flight, abort, gates, schedule, stopOn, hard safety rules)
- All of Epic E (library: local + remote, install, auto-update, rollback, delete)
- All of Epic F (distribution: notarize-in-CI, Sparkle, rollback path)

Plus the implicit deliverables:
- The five PS99 seed macros (`auto-hatch`, `auto-grind-biome-1`, `auto-rebirth`, `auto-fuse-pets`, `clan-battle-helper`)
- `schema/macro.schema.yaml` with codegen for Swift + TS types in CI
- `MacRoTheme` SwiftUI theme mapping 626Labs design tokens
- `tools/release/` notarization scripts + GitHub Actions workflow
- A public-facing landing page at `626labs.dev/macRo` (one-page, links to GitHub Releases)

## What we'd add with more time (v2+)

These are deferred from the spec (§ 11) and from this PRD's discussions:

- **Subsystem B (factory automation pipeline)** — TS/Bun. Detect game updates, generate N candidate patches, evaluate, ship the best. Own spec, own cycle.
- **Subsystem C (rich library)** — browse, rate, fork, comment. Replaces the static-feed stub.
- **Game Plugin Author Kit** — templated repo + `.claude/` skills for community plugin authors.
- **Multi-instance Roblox client management** — orchestrate many Roblox accounts simultaneously (Psycho Manager equivalent). Real demand; v2/v3 with eyes open since Roblox actively discourages it.
- **Discord webhook notifications** — `notify-discord` action on `stopOn` triggers + per-macro `webhookUrl` field. Forces a "user-supplied secret" flow we'd rather defer.
- **Auction / market sniping macros** — latency-sensitive single-action automation. Different problem shape than long-running grinds.
- **Schema v2 features** — variables / counters (`vars`, `incVar`, gate-on-var), OCR / number reading, sound resources, macro composition (`include: other.macro`).
- **Cross-game / multi-game macros** — engine-agnostic macros that work across multiple Roblox experiences (currently `target.windowTitleMatch` is single-string).
- **Cloud sync of user macros** — local-first by principle; would require accounts.

## Non-goals

The hardliners — these are NOT just "not in v1," they're "we will not ship these, ever, in macRo as currently scoped":

- **No telemetry of any kind.** Not error reporting, not usage analytics, not "anonymous diagnostics." Anonymous GitHub release download counts (which GitHub owns, not us) are the only signal. Any change here requires a logged decision AND a user-facing disclosure.
- **No marketplace, no payments.** Macros are free. macRo is free. Forever.
- **No anti-detection logic in the engine.** No obfuscation, no process injection, no detection-evasion. If a specific game introduces an active anti-macro check, we adapt the plugin or stop supporting that game — we do NOT pollute the engine.
- **No cross-platform.** Mac-native is the moat. No Electron retrofit, no Tauri "for portability," no Windows version.
- **No accounts, no auth, no cloud sync.** Local-first by principle. Users share macros via Discord / AirDrop / whatever.

## Open questions

Each tagged with whether it needs to be answered before `/spec` or can wait.

- **Image-similarity algorithm + thresholds** (Vision template match vs OpenCV ORB vs perceptual hash) — *can wait;* picked during prototype A/B, before v1 release.
- **Roblox FPS detection mechanism** (SCK frame timestamps vs OCR of in-game counter vs user-input fallback) — *answered:* auto-detect from SCK first, user-input fallback in Settings.
- **Sparkle EdDSA key generation timing + 1Password storage** — *can wait;* generated at first release tag.
- **PS99 canonical keybinding defaults** — *can wait;* Estevan records during seed-macro authoring (tracked as a /build item).
- **"What game?" sheet UX** (search field + dropdown) — *can wait;* defer to UX micro-iteration.
- **`MacRoTheme` token mapping precision** (which 626Labs CSS variables map to which SwiftUI types) — *can wait;* invoke the `626labs-design` skill at first SwiftUI authoring beat.
- **Library remote feed JSON shape** — *answered:* sketched in spec § 7; locked at the `schemaVersion: 1` shape.
- **Codegen tool choice** (Quicktype vs hand-written codegen vs Swift macros) — *can wait;* pick at first schema-codegen build item.
- **First marketing surface** (a `626labs.dev/macRo` landing page vs a dedicated `macro.626labs.com` subdomain) — *can wait;* not load-bearing for the app build.
- **Clan-battle macro mechanic** — *needs answer before /build item that authors the seed:* Estevan to brief the agent on what clan battles in PS99 actually require (UI states, position cues, currencies, stop-conditions worth defaulting on).
