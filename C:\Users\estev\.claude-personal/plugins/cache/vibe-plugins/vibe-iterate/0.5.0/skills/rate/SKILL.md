---
name: rate
description: "This skill should be used when the user says `/vibe-iterate:rate <idea>` and wants to score a feature idea against their shipped product. Reads the codebase + Atlas, scores on impact, fit-with-stack, effort, regression-risk, user-trust-impact. Outputs scores + rationale + ship-now/queue/decline verdict."
---

# /vibe-iterate:rate <idea> — score a feature idea against your shipped product

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior, then follow this command.

## Status

**Implementation pending.** v0.1.0 scaffold stub. Locked design lives in [`../../../../docs/2026-05-04-vibe-iterate-design.md`](../../../../docs/2026-05-04-vibe-iterate-design.md) — see *Sidecar tools → /vibe-iterate:rate*.

## Spec summary

- Takes a one-line idea ("add saved searches"). Reads the codebase + Atlas
- Output: scores on impact, fit-with-stack, effort, regression-risk, user-trust-impact + one-paragraph rationale + one-line *ship-now / queue / decline* verdict
- Used internally by every banner mode to rank candidates

## Implementation references

- Spec: `docs/2026-05-04-vibe-iterate-design.md` — *Sidecar tools → /vibe-iterate:rate*; *Banner modes / ux-polish — User-trust-impact rubric*
- Shared guide: [`../guide/SKILL.md`](../guide/SKILL.md)
