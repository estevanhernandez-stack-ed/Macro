---
name: vibe-iterate
description: "This skill should be used when the user says `/vibe-iterate` (bare, no subcommand). Reads project state (Atlas, radar cache, recent commits), recommends a mode for the moment (feature-add, competitive, ux-polish, bug-bash), and asks before launching. Never auto-fires."
---

# /vibe-iterate — bare router

Read [`../guide/SKILL.md`](../guide/SKILL.md) for shared agent behavior (Ptolemy persona, posture, knowledge sources, Atlas conventions, Cart-detection), then follow this command.

## What this command does

Bare router. The user invoked `/vibe-iterate` with no subcommand — they want help choosing a mode. The agent's job is to:

1. Read the project's current state (Atlas, radar cache, recent commits, branch state, presence of `feedback.md`)
2. Synthesize: what's the most useful mode RIGHT NOW for this project?
3. Recommend ONE mode with rationale
4. Surface 1-2 alternatives, with rationale for why they're second/third
5. Ask the user to confirm before launching anything

## Hard rules

- **Never auto-fire a mode.** Always ask the user before invoking another command.
- **Read-only by default.** This command does NOT write to the Atlas, the config, or any project file.
- **One recommendation, with alternatives.** Don't surface a 5-mode menu; that's not a recommendation.

## Project state to read (in order)

1. **Atlas (`.vibe-iterate/atlas.jsonl`).** If absent, this is a first run — flag it ("First-time vibe-iterate run on this project. I'll need to infer your category and competitors before any banner mode can run productively.").
2. **Config (`.vibe-iterate/config.json`).** If absent or `last_inferred_at` is >30 days old, suggest re-inference as a separate first move.
3. **Radar cache (`.vibe-iterate/radar.cache.json`).** If absent or `refreshed_at` is >14 days old, suggest a `/vibe-iterate:radar` refresh as a follow-up.
4. **Recent commits.** Last 10 on the current branch. What's been shipped recently?
5. **Branch state.** On `main`? On a feature branch? Any uncommitted changes?
6. **`feedback.md` presence.** If present, surface it as input for Bug-bash candidate.

## Mode recommendation logic

Pick ONE based on the strongest signal:

| Signal | Recommend |
|---|---|
| `feedback.md` exists with unaddressed items, AND last Atlas-shipped item was >7 days ago | **bug-bash** — users have things to say, address them |
| Radar cache shows >3 framework releases since last shipped iteration | **feature-add** — fresh framework features may unblock prioritized items |
| Radar cache shows competitor changelogs with new items in user's category | **competitive** — gap-close opportunity |
| Recent commits show 3+ feature lands but no polish PRs | **ux-polish** — the surfaces are getting rough |
| Atlas shows >5 recent shipped entries, no rejected ones | **(soft suggest)** review the Atlas; you may be over-shipping without considering tradeoffs |
| First run, config not yet inferred | **(meta)** "Let me infer your category and competitors first — confirm to proceed?" |

When two signals tie, prefer the mode the user has invoked LEAST recently (per Atlas history).

## Output shape

Render the recommendation in this structure:

```
**Recommendation:** /vibe-iterate:<mode>

Why:
- [signal 1, with one-line evidence]
- [signal 2, with one-line evidence]

Alternatives:
- /vibe-iterate:<other-mode-1> — [why this is second]
- /vibe-iterate:<other-mode-2> — [why this is third]

Project state:
- Atlas: <N entries, last shipped YYYY-MM-DD>
- Config: <inferred YYYY-MM-DD>
- Radar cache: <refreshed YYYY-MM-DD>
- Branch: <main or feature/...>
- feedback.md: <present|absent>

Run /vibe-iterate:<mode>? (yes / pick alternative / not now)
```

Wait for the user's response. Do NOT invoke any subcommand on your own.
