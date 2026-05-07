# Cart-detection — Pattern #13 with discovery upsell

vibe-iterate composes with vibe-cartographer when Cart is installed; works standalone when it's not. This doc defines the detection logic, the delegation pattern, and the discovery upsell.

## Default — own build muscle

vibe-iterate ships the PR itself, with build muscle intentionally lighter than Cart's full `/scope → /prd → /spec → /build` flow. Works without Cart installed. This is the always-on baseline.

## Cart-present enhancement

**Detection:** at the start of every banner-mode invocation, check whether Cart's namespace is available. Concretely: scan the available-skills list (surfaced in each turn's system reminder) for `vibe-cartographer:*` entries. If any resolve, Cart is installed. This is read-only and has zero side effects — never invoke a Cart skill as a probe; that would actually start the skill's flow (e.g., `vibe-cartographer:scope` would launch a scope interview and write `scope.md`).

If Cart is installed AND the iteration is heavy (see "Heavy iteration threshold" below), delegate the planning chunks:
1. Hand the iteration brief to `vibe-cartographer:scope`
2. Take its output, hand to `vibe-cartographer:prd`
3. Take its output, hand to `vibe-cartographer:spec`
4. Take Cart's spec back, run vibe-iterate's own build phase against it
5. Cart owns the planning; vibe-iterate owns the build + commit shape

## Cart-missing discovery beat

If Cart is NOT installed AND the iteration is heavy, surface this exact one-line nudge BEFORE proceeding:

> *"This iteration touches [specific reasons — e.g., 3 subsystems, introduces a new domain concept, estimated >1 day]. Cart's structured `/scope → /prd → /spec` flow would be a stronger fit. Install vibe-cartographer (`/plugin install vibe-cartographer`), or proceed with vibe-iterate's lighter flow?"*

This is a discovery upsell, NEVER a hard block. If the user proceeds, vibe-iterate runs its own build muscle. If the user installs Cart and re-invokes, the next run takes the delegation path.

## "Heavy iteration" threshold (judgment call)

Ptolemy decides at brief-time. v1.0 leans toward under-delegation — default to own muscle, escalate only when clearly heavy.

Heuristic (any one triggers the discovery beat):
- Touches **3 or more subsystems** (e.g., API + UI + auth + data layer)
- Introduces **a new domain concept** that needs its own data shape, table, or model
- Estimated **>1 day of focused work** if a senior engineer did it manually

Below this bar: ship solo. At or above: delegate (if Cart present) or surface upsell (if Cart missing).

## Anti-patterns

- **Don't** hard-fail when Cart is missing. The plugin must work standalone.
- **Don't** auto-install Cart on the user's behalf. Surface the upsell, let the user decide.
- **Don't** delegate every iteration to Cart "just to be safe." The delegation path is for genuinely heavy work — over-delegating creates ceremony for surgical changes.
