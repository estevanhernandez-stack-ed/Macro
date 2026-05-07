---
name: upgrade
description: "This skill should be used when the user says `/vibe-iterate:upgrade <package>` and wants to surgically bump one library to its latest version with codemods if available. Reads release notes, runs codemod if exists, runs test suite, ships the bump as one PR."
---

# /vibe-iterate:upgrade <package> — surgical library bump

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Sidecar tools → /vibe-iterate:upgrade*.

## Spec summary

- Surgical version of the cut Modernize banner mode. Single-package focus
- Reads release notes, runs the codemod if one exists, runs the test suite, ships the bump as one PR
- Output: one upgrade PR + Atlas entry with `mode: upgrade`
- Used in response to a `:scan-releases` finding or a security advisory

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Sidecar tools → /vibe-iterate:upgrade*; *Out of scope — Modernize banner mode*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
