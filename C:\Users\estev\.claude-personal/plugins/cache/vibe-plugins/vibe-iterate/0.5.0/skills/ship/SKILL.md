---
name: ship
description: "This skill should be used when the user says `/vibe-iterate:ship <brief>` and wants to skip ingestion and ship from a hand-written brief. Takes a markdown brief (or inline prompt), runs the build with regression-aware/small-diff posture, ships one PR + Atlas entry."
---

# /vibe-iterate:ship <brief> — skip ingestion, ship from a brief

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Sidecar tools → /vibe-iterate:ship*.

## Spec summary

- Takes a markdown brief (file path or inline prompt). No ingestion phase
- Runs the build directly with regression-aware / small-diff posture
- Output: one PR + Atlas entry with `mode: ship`
- Bypasses the signal-ingestion phase for users who already know what they want

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Sidecar tools → /vibe-iterate:ship*; *Architecture → "Heavy iteration" threshold*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md) — build engine, Cart-detection
