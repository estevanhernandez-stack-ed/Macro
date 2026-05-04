# macRo schema codegen

Hand-written Bun/TypeScript codegen that turns `schema/macro.schema.yaml`
into Swift `Codable` types at `App/macRo/Schema/MacroFormat.swift`.

## Why hand-written?

Quicktype was the obvious choice but produces weak Swift for our needs:

- Our `TimelineEvent` is a discriminated union on `kind` with kind-specific
  required fields — Quicktype would flatten this to a struct of all-optional
  fields, losing the type safety that makes the schema valuable.
- Our `onFail` / `action` strings are polymorphic (literal enum OR `sub:<name>`
  pattern) — same story.
- Our schema is JSON-Schema-shaped YAML with comments and intentional
  conventions; we control the input shape, so a small generator keeps the
  emitted Swift idiomatic.

The generator is ~500 lines and only models the schema subset we use. New
schema shapes need matching support in `src/schema.ts` (typed view) and
`src/emit-swift.ts` (emitter). That's the contract — there are no shortcuts.

## Run it

From the repo root:

```bash
bun run codegen
```

That alias resolves to `cd tools/codegen && bun run src/generate-types.ts`.
The emitted file lands at `App/macRo/Schema/MacroFormat.swift` and is
committed alongside the schema. **Never hand-edit the Swift file.**

## CI lockstep guard

`.github/workflows/ci.yml` runs the generator and `git diff --exit-code`s
the output against `HEAD`. Any drift fails CI. The intent: schema and Swift
move together in one commit, always.

## Adding a new schema field

1. Edit `schema/macro.schema.yaml`.
2. From repo root, run `bun run codegen`.
3. Inspect `App/macRo/Schema/MacroFormat.swift` — confirm the new field
   appears as expected.
4. Build the Xcode project (`cd App && xcodegen generate && xcodebuild -scheme macRo build`).
5. Commit schema + Swift + any consumer updates in one commit.

## Adding a new schema *shape*

If you introduce a shape the generator doesn't support yet — a new `oneOf`
flavor, a `$ref` form we don't handle, JSON Schema features like `allOf`
or conditional schemas — extend `src/schema.ts` (the typed view) and
`src/emit-swift.ts` (the emitter) before introducing the new shape into
the schema. The generator surfaces unsupported shapes as `String`
fallbacks; that's a code smell, not a feature.

## Mapping decisions (locked at item 2)

- Each top-level `$defs` entry → one Swift type (struct OR discriminated enum).
- `oneOf` where every branch fixes a `kind` const → Swift `enum` with
  associated-value cases + custom `init(from:)` / `encode(to:)`.
- Polymorphic strings (literal-enum + `sub:<name>` pattern) → typed enum
  with `.literal(Literal)` + `.subInvocation(name: String)`.
- Inline anonymous objects → nested struct named `<Parent><Property>`.
- `additionalProperties: <SchemaNode>` → `[String: <Type>]` (used for
  `timeline.subs`).
- Required-vs-optional follows the parent object's `required` array; everything
  else is `?` with a `nil` default in `init`.

If any of these change, log a decision and update this README in the same
commit as the schema/codegen change.
