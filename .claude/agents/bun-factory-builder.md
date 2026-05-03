---
name: bun-factory-builder
description: TS/Bun development assistance for the factory pipeline (Subsystem B). Knows about the multi-candidate patch evaluator architecture, the `.macro` schema (shared with Swift via codegen), and the accuracy-first publishing discipline. Activates when working in `tools/factory/`.
tools: Read, Glob, Grep, Bash, Edit, Write
model: sonnet
---

**STUB — to be expanded when Subsystem B (factory pipeline) work begins. Has its own spec doc to be written.**

Future scope:
- TS/Bun conventions specific to macRo (carry from sibling 626Labs TS repos when established)
- Schema codegen: keep `tools/factory/` types in lockstep with `schema/macro.schema.yaml`
- Multi-candidate patch generation + evaluation (the accuracy-first discipline from Section 7 of the design spec)
- Game patch detection via per-game patch feeds (Discord changelog scraping, asset diffs)
- Factory CLI surface: `bun run patch <macro-id>`, `bun run evaluate <candidate>`, `bun run publish`
- Sandboxed test environment for patch playback verification

Until Subsystem B begins (later spec, separate cycle), this agent has nothing to do. Re-read this stub when scoping the factory pipeline.
