# Knowledge sources — how Ptolemy stays cutting-edge

Three layers, in priority order at decision-time.

## 1. context7 MCP (primary, live)

**When to use:** at decision-time, whenever the agent reaches for "is there a current way to do X in [framework]?"

**Why:** context7 returns fresh framework docs (Next, React, Tailwind, Prisma, Express, Django, etc.) that may differ from training-data knowledge. Even for libraries the agent thinks it knows, context7 is preferred over web search for library-specific syntax, configuration, and migration questions.

**Usage:** call `mcp__context7__resolve-library-id` to get the canonical library ID, then `mcp__context7__query-docs` with the question.

**Fallback if missing:** if the user doesn't have the context7 MCP configured, fall through to layer 3 (web search).

## 2. Scheduled refresh cache (primary, fast)

**When to use:** whenever a banner mode or sidecar wants the "what's new" picture for the project's stack and competitor set, BEFORE doing any live lookup. The cache is the cheap first-pass scan.

**Where it lives:** `.vibe-iterate/radar.cache.json` in the host project. Schema: `skills/guide/schemas/radar-cache.schema.json`.

**How it gets refreshed:** weekly job via the `schedule` plugin's cron. The job reads `.vibe-iterate/config.json` for `framework_pins[]` and `competitors[]`, queries each, and writes the cache.

**Read pattern:**
- `:radar` reads the cache directly and renders a digest
- Banner modes read the cache as their first move; if cache is stale (>14 days) or missing, surface a one-line nudge: *"Radar cache is stale (last refreshed YYYY-MM-DD). Run `/vibe-iterate:radar` after the next scheduled refresh, or invoke a manual refresh."*

## 3. Web search (fallback)

**When to use:** when context7 doesn't cover the library, or context7 is unavailable, OR when the question is about something context7 doesn't index (Product Hunt category trends, competitor blog posts, HN/Reddit discussions about similar apps).

**Usage:** the standard `WebSearch` and `WebFetch` tools.

**Quality bar:** prefer official sources (vendor changelogs, release notes, GH releases) over secondary commentary. Cite the URL when surfacing a finding to the user.

## Anti-patterns

- **Don't** rely on training-data knowledge alone for "what's the current X?" — even when you're confident. Use context7 or web search to verify.
- **Don't** scrape competitor URLs at every banner-mode invocation. The cache exists for a reason; use it.
- **Don't** lean on web search when context7 covers the library. context7 is faster, more reliable, and fewer ambiguous matches.
