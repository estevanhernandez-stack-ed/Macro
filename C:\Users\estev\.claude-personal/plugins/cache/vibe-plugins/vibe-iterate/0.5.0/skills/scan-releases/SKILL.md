---
name: scan-releases
description: "This skill should be used when the user says `/vibe-iterate:scan-releases [package]` and wants to know what's new in a specific lib (or all libs) since they last bumped. Reads package.json pins, queries release notes via context7 + web search, outputs per-package list of breaking changes, new features, security fixes, codemod availability."
---

# /vibe-iterate:scan-releases [package] — what's new since you last bumped

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Sidecar tools → /vibe-iterate:scan-releases*.

## Spec summary

- Optional `[package]` arg. If absent, scans all libs in `package.json`
- Reads pins, queries release notes (context7 when present, web search as fallback) since the pinned version
- Output: per-package list of breaking changes, new features, security fixes. Flags codemod availability
- Used internally by `feature-add` ("is there a fresh framework feature that unblocks the highest-impact item?") and by `:upgrade` for the bump itself

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Sidecar tools → /vibe-iterate:scan-releases*; *Cutting-edge knowledge*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
