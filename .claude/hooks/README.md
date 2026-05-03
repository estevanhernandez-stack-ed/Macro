# Hooks — macRo

**STUB — both hooks land here once their target surfaces exist. Wiring (in `.claude/settings.json`) is deferred until the trigger files are real, so the hooks don't fire against nothing.**

## Planned hooks

### 1. Schema codegen (PostToolUse on Edit for `schema/macro.schema.yaml`)

When `schema/macro.schema.yaml` is edited, automatically run `bun run codegen` to regenerate Swift `MacroFormat` and TS schema types in lockstep. Closes the schema-drift feedback loop the moment it could open.

**Wires up when:** `schema/macro.schema.yaml` exists AND a `bun run codegen` script exists.

**Hook config (planned, for `settings.json`):**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": { "tool": "Edit", "filePathPattern": "schema/macro.schema.yaml" },
        "command": "bun run codegen"
      }
    ]
  }
}
```

### 2. Pre-commit secret scan

Scan staged files for accidentally-committed secrets before `git commit` succeeds: Sparkle private key (`Ed25519` armored format), Apple Developer ID certificates (`.p12`, `.pem`), `.env` contents, AWS keys, GitHub PATs.

**Wires up when:** the first sensitive material is anywhere in this repo's reach (notarization scripts arriving, `.env.local` introduced, etc.).

**Implementation candidates:**

- `gitleaks` (Go binary, `brew install gitleaks`) — well-maintained, fast
- `trufflehog` (Python, more thorough) — slower, deeper detection
- A small custom Bun script if neither feels right

The hook fails the commit; the user must either remove the secret or move it to GitHub-hosted secrets / 1Password.

## Why these aren't wired up yet

Hooks that fire against nothing are noise. The schema hook needs a schema file to watch. The pre-commit hook needs sensitive material in scope. Until then, this README is the placeholder so the next agent landing here knows what's planned.
