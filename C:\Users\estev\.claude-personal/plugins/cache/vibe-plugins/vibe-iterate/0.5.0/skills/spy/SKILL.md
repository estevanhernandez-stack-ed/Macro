---
name: spy
description: "This skill should be used when the user says `/vibe-iterate:spy <url>` and wants a one-shot competitive read on a single URL. Fetches and reads the URL (changelog, what's-new, landing page), outputs structured read of what they shipped, what they emphasize, gaps, and overlap."
---

# /vibe-iterate:spy <url> — one-shot competitive read

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Sidecar tools → /vibe-iterate:spy*.

## Spec summary

- Takes a single URL argument (changelog, "what's new" page, landing page, GH releases page)
- Fetches and reads it
- Output: structured read — what they shipped, what they emphasize, gaps you might have, things you do better
- Used internally by `competitive` mode for each user-supplied competitor URL

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Sidecar tools → /vibe-iterate:spy*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
