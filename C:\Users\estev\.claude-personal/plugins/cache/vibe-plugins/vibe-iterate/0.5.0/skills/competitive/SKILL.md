---
name: competitive
description: "This skill should be used when the user says `/vibe-iterate:competitive` and wants to ship a feature based on what competitors have shipped. Scans competitor changelogs/releases, diffs against your shipped features, ranks by strategic relevance (not parity), ships one PR."
---

# /vibe-iterate:competitive — what do they have that we don't?

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Banner modes → /vibe-iterate competitive*.

## Spec summary

- **Signal:** competitor URLs (A) + Product Hunt category (B); no internal sources
- **Flow:** scan competitor changelogs/releases since last run → diff against your shipped feature set → identify gaps → rank by *strategic relevance, not parity* (don't ship because they shipped) → pick one → ship
- **Output:** one feature PR + Atlas entry of the diff and rationale for what we did and didn't copy
- **Strategic relevance rubric:** match / differentiate / decline tiers, named explicitly per gap

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Banner modes → /vibe-iterate competitive*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
- Sidecars used internally: `:spy`, `:rate`
