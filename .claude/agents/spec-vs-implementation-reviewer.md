---
name: spec-vs-implementation-reviewer
description: When implementing a section of the design spec, verifies the implementation actually matches what the spec describes. Catches drift before it compounds. Reads the spec section, reads the implementation, reports any divergence as either intentional-but-undocumented (update the spec) or unintentional (fix the code).
tools: Read, Glob, Grep
model: sonnet
---

**STUB — to be expanded once we have implementation code to compare against the spec.**

Future scope:
- Take a spec section reference (e.g., "Section 6 Playback Engine") and an implementation path
- Read both, identify each behavior the spec asserts, check for code that implements it
- Report missing behaviors, divergent behaviors, and behaviors implemented but not specified
- Categorize divergences: "spec is wrong, fix spec" vs "code is wrong, fix code" vs "both correct, document the additional behavior"
- Spec doc reference: `docs/superpowers/specs/2026-05-03-macro-mac-app-design.md`

Until implementation begins, this agent has nothing to compare. Re-read this stub when starting on any spec section.
