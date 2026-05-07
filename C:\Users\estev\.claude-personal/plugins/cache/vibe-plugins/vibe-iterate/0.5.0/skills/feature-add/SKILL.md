---
name: feature-add
description: "This skill should be used when the user says `/vibe-iterate:feature-add` and wants to ship the next feature. Scans competitor URLs, Product Hunt, framework releases, and feedback.md. Clusters candidates, scores on impact/fit/effort/Atlas-history, ships one PR."
---

# /vibe-iterate:feature-add — what should we build next?

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior (Ptolemy persona, posture, knowledge sources), then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Banner modes → /vibe-iterate feature-add*.

## Spec summary

- **Signal:** competitor URLs (A) + Product Hunt category (B) + framework releases (E) + `feedback.md` if present
- **Flow:** scan signal → cluster into candidate features → score on impact, fit-with-stack, effort, and Atlas history (don't re-propose recently rejected items) → pick one → produce brief → ship the PR
- **Output:** one feature PR + Atlas entry logging the candidates considered, the one chosen, the runners-up

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Banner modes → /vibe-iterate feature-add*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
- Sidecars used internally: `:radar`, `:rate`
