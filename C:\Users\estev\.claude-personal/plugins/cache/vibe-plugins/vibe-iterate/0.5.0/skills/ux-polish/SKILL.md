---
name: ux-polish
description: "This skill should be used when the user says `/vibe-iterate:ux-polish` and wants to fix shipped-but-rough UI surfaces. Walks routes/components/key flows, identifies rough patches (inconsistent spacing, weak hierarchy, missing states, dead-end paths), scores by user-trust impact, ships one polish PR."
---

# /vibe-iterate:ux-polish — what's shipped but rough?

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Banner modes → /vibe-iterate ux-polish*.

## Spec summary

- **Signal:** none external. Agent walks the shipped UI surfaces (routes, components, key flows)
- **Flow:** identify rough patches (inconsistent spacing, weak hierarchy, missing empty/loading/error states, dead-end paths) → score by user-trust impact → pick one → ship the polish PR
- **Output:** one polish PR + Atlas entry of the rough-spot catalog
- **User-trust-impact rubric:** breaks-trust / erodes-trust / cosmetic tiers (same rubric used by `:rate`)

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Banner modes → /vibe-iterate ux-polish*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
- Sidecars used internally: `:rate`
