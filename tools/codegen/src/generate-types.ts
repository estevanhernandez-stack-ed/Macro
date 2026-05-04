// generate-types.ts — entry point for the schema → Swift codegen.
//
// Run from repo root:
//   bun run codegen
//
// Reads:    schema/macro.schema.yaml
// Writes:   App/macRo/Schema/MacroFormat.swift
//
// Exit codes:
//   0 — wrote (or no-op if already in sync)
//   1 — usage / IO error
//   2 — schema parse error
//   3 — emit error

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { parse as parseYaml } from "yaml";
import { emitSwift } from "./emit-swift.ts";
import type { RootSchema } from "./schema.ts";

// Repo root resolution: this file lives at <repo>/tools/codegen/src/generate-types.ts.
// import.meta.dir is the directory of THIS source file.
const SCRIPT_DIR = import.meta.dir;
const REPO_ROOT = resolve(SCRIPT_DIR, "..", "..", "..");

const SCHEMA_PATH = resolve(REPO_ROOT, "schema", "macro.schema.yaml");
const OUTPUT_PATH = resolve(REPO_ROOT, "App", "macRo", "Schema", "MacroFormat.swift");

function main(): number {
    let yamlText: string;
    try {
        yamlText = readFileSync(SCHEMA_PATH, "utf-8");
    } catch (err) {
        console.error(`[codegen] failed to read schema at ${SCHEMA_PATH}`);
        console.error(err);
        return 1;
    }

    let parsed: unknown;
    try {
        parsed = parseYaml(yamlText);
    } catch (err) {
        console.error(`[codegen] YAML parse error in ${SCHEMA_PATH}`);
        console.error(err);
        return 2;
    }

    if (!parsed || typeof parsed !== "object") {
        console.error(`[codegen] schema root is not an object`);
        return 2;
    }

    const schema = parsed as RootSchema;
    if (!schema.$defs) {
        console.error(`[codegen] schema is missing required \`$defs\` block`);
        return 2;
    }

    let swiftText: string;
    try {
        swiftText = emitSwift(schema);
    } catch (err) {
        console.error(`[codegen] Swift emission error`);
        console.error(err);
        return 3;
    }

    try {
        mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
        writeFileSync(OUTPUT_PATH, swiftText, "utf-8");
    } catch (err) {
        console.error(`[codegen] failed to write ${OUTPUT_PATH}`);
        console.error(err);
        return 1;
    }

    console.log(`[codegen] wrote ${OUTPUT_PATH} (${swiftText.length} bytes)`);
    return 0;
}

process.exit(main());
