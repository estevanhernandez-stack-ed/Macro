---
name: bug-bash
description: "This skill should be used when the user says `/vibe-iterate:bug-bash` and wants to fix the highest-priority user-reported bug. v1.0: reads `feedback.md` only. Triages by severity × frequency × blast-radius, reproduces, ships the fix as one PR."
---

# /vibe-iterate:bug-bash — what's broken according to users?

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Banner modes → /vibe-iterate bug-bash*.

## Spec summary

- **Signal v1.0:** `feedback.md` only (escape hatch). Real connectors (GH Issues, Discord, Dashboard) defer to v1.1
- **Flow:** read the feedback file → triage by severity × frequency × blast-radius → pick highest-priority → reproduce → ship the fix
- **Output:** one fix PR + Atlas entry of the bug, reproduction, fix
- **v1.0 caveat:** dormant for repos without `feedback.md`. Surfaces a one-line nudge: *"No internal signal connected. Add a feedback.md, or wait for v1.1."*

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Banner modes → /vibe-iterate bug-bash*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
