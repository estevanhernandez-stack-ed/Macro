# Atlas conventions

The Atlas is the per-project ledger of every iteration vibe-iterate has considered, shipped, or rejected. Lives at `.vibe-iterate/atlas.jsonl` in the host project. JSONL — one JSON object per line, append-only, never edited.

## Why the Atlas exists

- **Don't re-propose the same thing twice.** Modes read the Atlas before scoring candidates; recently rejected items are demoted.
- **Build a navigable history.** Future-you (or a teammate) can scan the file and understand what was tried, what shipped, what was passed on, and why.
- **Compose with other plugins.** vibe-doc / vibe-test / vibe-sec can read the Atlas to scope their work to recently changed surfaces.

## Entry shape

See [`../schemas/atlas-entry.schema.json`](../schemas/atlas-entry.schema.json) for the canonical schema. Fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | ISO-8601 datetime | yes | UTC; when the entry was written |
| `mode` | enum | yes | `feature-add` \| `competitive` \| `ux-polish` \| `bug-bash` \| `ship` \| `upgrade` |
| `outcome` | enum | yes | `shipped` \| `rejected` \| `queued` |
| `title` | string | yes | One-line iteration title |
| `rationale` | string | yes | Why this iteration; why this outcome |
| `rejected_runners_up` | string array | yes | Iteration candidates considered but not picked. Empty array when N/A |
| `pr` | string \| null | yes | PR URL when `outcome == "shipped"`, else null |

## Write rules

- **Append-only.** Never edit existing lines; never delete the file. If a correction is needed, append a new entry that supersedes (with rationale referencing the prior entry).
- **One entry per banner-mode or sidecar invocation that ships, rejects, or queues something.** Read-only sidecars (`:radar`, `:spy`, `:scan-releases`, `:rate`) do NOT write Atlas entries.
- **Validate before write.** Read the schema (or use the in-plugin reference at `../schemas/atlas-entry.schema.json`); ensure required fields are present and enums are correct. A malformed entry corrupts the ledger for everyone downstream.
- **Atomic write.** If using a file API, prefer line-buffered append. Don't read-modify-write the whole file (race risk).

## Read patterns

- **Recent-rejection check.** When scoring a new candidate, scan the last N entries (default: 30 days) for `outcome == "rejected"` matches; demote if matched.
- **What-shipped review.** `/vibe-iterate` (bare router) reads the last K shipped entries to ground its mode recommendation.
- **Cross-plugin scope.** Other 626Labs plugins MAY read the Atlas to scope work; they MUST treat it as read-only.

## Privacy

The Atlas stays local to the project. **No telemetry, no phone-home.** If a user wants to share their Atlas (e.g., for a debrief), that's a manual `cat .vibe-iterate/atlas.jsonl` away. Per Este's standing rule: vibe-iterate emits no usage pings.
