# Builder Profile

> **Cycle #14** for Estevan. Spec-first cycle (Substrate pattern (mm) from cycle #13). Returning builder, all decay fields fresh, autonomous mode on.

## Who They Are

**Estevan** ("Mr. Solo Dolo" — handle from LADDER). Builder and outsider. Runs **626Labs LLC** out of Fort Worth, TX. 20+ years of PC/Windows experience. Vibe coder by practice — architects and ships through AI agents rather than writing code directly; strong pattern recognition, troubleshooting, and systems thinking. Has shipped ~10 deployed apps including a 7-app enterprise suite under serious consideration for company deployment, three Microsoft Store apps, theatre ops tools, hackathon apps, Roblox games, Claude Code plugins, Discord bots, and a portfolio site at `626labs.dev`. Active **Vibe Cartographer plugin contributor** — modified the plugin for company use; LADDER (Apr 2026) was the retooled-plugin stress test before this whole wave of Cart projects.

## Technical Experience

**Level:** experienced.

**Languages on file:** TypeScript, Python, JavaScript, Luau, C#, HTML/CSS, C++.

**Frameworks on file:** React 19, Next.js, Vite, TailwindCSS, Firebase, FastAPI, Flask, Express, .NET 8/9, Azure, Expo, React Native, Drizzle ORM, Playwright, WPF, C++/WinRT, Windows App SDK / WinUI 3, MSIX / wapproj, Ollama, Gemma 4 (E4B + 26B-A4B).

**Project-specific stack additions (this cycle, NOT added to global identity):**

- **Swift / SwiftUI** — for the Mac app (Subsystem A)
- **ScreenCaptureKit, CGEventTap, AVFoundation, NSAccessibility** — Apple platform APIs (capture, input record/synthesis, encoding, window detection)
- **Sparkle 2.x** — Mac auto-update framework
- **Bun** — for the factory pipeline (Subsystem B, later cycle)

These are project tools, not "languages Estevan codes in." Per the "don't fabricate" rule of the unified profile, they're scoped to this `docs/builder-profile.md` rather than the global `shared.technical_experience.*` arrays.

**AI agent experience:** Deep. Built and shipped Claude Code plugins (Vibe Cartographer, Vibe Doc, Vibe Test) to marketplace. Modified Vibe Cartographer for company use. Runs Claude Code as an autonomous build system with structured checklists and subagent delegation — proven across 13+ Cart cycles. Willing to switch agents mid-project when one is stuck — neutral tool, not a threat.

## Mode

**Builder.** Streamlined flow, less explaining, more doing. `autonomy_level: fully-autonomous` in the unified profile (set 2026-04-26 after 9 completed Cart cycles, rich profile, cycle-brief pattern proven). This run honored the autonomous setting at the pacing gate.

## Project Goals

**macRo** — the Mac macro maker for Roblox. v1 design locked in the spec at `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`.

The end goal is a **Mac-native macro maker and player** that beats the Windows-only competition (Psycho Hatcher etc.) on three axes:

1. **Authoring UX** — iMovie-flavored video-editor metaphor (record gameplay → scrub timeline → cut dead air → the inputs in what's left become the macro). Targets the player who knows what macros do but can't author one in a script.
2. **Mac-native posture** — ScreenCaptureKit, CGEventTap, real Apple APIs. Not Electron, not Tauri.
3. **Factory pipeline** — diff-able text macro bundles + a TS/Bun factory that generates N candidate patches per game update, evaluates each against the new game state, ships only the highest-scoring candidate. **Accuracy-first as the public commitment; speed as internal motivation.**

**Hard constraints:**

- **No telemetry, ever.** Anonymous GitHub release download counts (which we don't even own — GitHub does) are the only signal. No analytics SDK, no error reporters that ship without per-incident consent.
- **Local-first.** No auth, no accounts, no cloud sync. Users share `.macro` bundles via Discord/AirDrop/whatever.
- **Free.** No marketplace, no payments. Ever.
- **Pet Simulator 99 first.** Engine is game-agnostic from day one; PS99 is the v1 anchor + first factory plugin. Community-authored plugins from v2 onward.

**Wedge use case (Estevan's actual use):** clan-battle macros for PS99 — the `clan-battle-helper.macro` is one of the v1 seeds and the personal motivation behind the cycle.

## Design Direction

**626Labs design system.** Cloned at `~/projects/626labs-design/`; available as the `626labs-design` Claude Code skill at `~/.claude/skills/626labs-design/`. Foundations:

- **Dark-mode first.** Deep navy field (`#091023`–`#192e44`).
- **Signature duo:** neon cyan `#17d4fa` + magenta `#f22f89`, always paired.
- **Product-specific accent:** teal `#2ee6c9` for primary CTAs and active nav.
- **Type:** Space Grotesk (display), Inter (UI), JetBrains Mono (code/meta — uppercase + 0.12em tracking).
- **Voice:** builder-to-builder, second person, sentence case, em-dashes welcome, no emoji in product UI, periods at the end of microcopy.

**Visual precedent:** **Sanduhr für Claude** is an existing 626Labs SwiftUI Mac app — the visual reference for HUD overlays in macRo (RecorderHUD, RunHUD).

When designing new screens, **invoke the `626labs-design` skill** rather than re-deriving tokens from memory.

## Prior SDD Experience

**Deep.** 13 prior Cart cycles completed. Active VC plugin contributor (modified the plugin for company use; ships patches to it). Recognizes structured planning as load-bearing — the brainstorm + spec + keystone work that preceded this /onboard is itself a deliberate Cart practice (the "spec-first" cycle pattern (mm) named in cycle #13's reflection).

`/reflect` doesn't need to over-explain SDD theory at the end of this cycle. The "what did we learn about the practice itself" beat is welcome and high-signal.

## Architecture Docs

**Yes — primary architecture surface is the design spec.**

- **`docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`** (535 lines, 12 sections) — load-bearing source of truth for *what we're building*. Three-subsystem architecture (Mac app, factory pipeline, library), `.macro` bundle format as the contract, schema source-of-truth at `schema/macro.schema.yaml` (planned), engine semantics, distribution, factory hooks, visual treatment, plugin model, PS99 v1 surface, out-of-scope, risks, references.
- **`CLAUDE.md`** (132 lines) — operational guidance for *how to work in this repo*. References the spec; doesn't restate it. 9 macRo-specific "what NOT to do" guardrails (no anti-detection, no telemetry, no Mac-native compromise, schema-as-single-source-of-truth, etc.).
- **`~/projects/626labs-design/`** — design system source (cloned 2026-05-03 from `github.com/estevanhernandez-stack-ed/626labs-design`).
- **`.claude/agents/`** — two production agents (`swift-mac-app-reviewer`, `macro-bundle-validator`) + three stubs (`design-system-applier`, `spec-vs-implementation-reviewer`, `bun-factory-builder`). Three rule stubs at `.claude/rules/`. One hooks README at `.claude/hooks/`.

`/spec` should treat the design spec as authoritative and produce a thinner spec-stub that points at it (cycle-13 (mm) pattern). Same for `/scope` and `/prd` — likely both compress significantly given the upstream is dense and validated.

## Deployment Target

**GitHub Releases** with signed + notarized DMG, **Sparkle 2.x EdDSA** for auto-update, appcast hosted on GitHub Pages. CI-driven notarization via GitHub Actions tagged on `v*` tags. Sparkle private key in 1Password. Detailed in spec § 7.

*This is a change from the prior cycle's deployment target (`marcus-landing-zone-azure-devops`). macRo is a **626Labs project**, not a Marcus tenant project — different deployment shape, different identity boundary.*
