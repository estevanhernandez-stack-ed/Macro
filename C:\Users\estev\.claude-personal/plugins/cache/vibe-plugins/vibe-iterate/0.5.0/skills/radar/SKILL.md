---
name: radar
description: "This skill should be used when the user says `/vibe-iterate:radar` and wants a read-only digest of what's new across their stack and competitor set since last visit. Reads the cached scheduled-refresh file (per-project, weekly). No mode run, no PR — just the digest."
---

# /vibe-iterate:radar — what's new since last visit

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Sidecar tools → /vibe-iterate:radar*.

## Spec summary

- Read-only. No mode run, no PR
- Reads `.vibe-iterate/radar.cache.json` (refreshed weekly via the `schedule` plugin's cron)
- Output: digest grouped by category — framework releases / competitor changelogs / Product Hunt buzz. Highlights deltas since last `:radar` call
- Used internally by every banner mode as the cheap first-pass scan

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Sidecar tools → /vibe-iterate:radar*; *Cutting-edge knowledge*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
