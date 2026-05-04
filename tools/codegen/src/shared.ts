// shared.ts — naming utilities, header banner, formatting helpers.
//
// All helpers are pure / stateless so the generator stays deterministic.

/**
 * Header banner emitted at the top of every generated file. The phrase
 * "GENERATED FROM" is the load-bearing string the CI lockstep guard greps
 * for if we ever add a guard beyond `git diff --exit-code`.
 */
export const SWIFT_HEADER = `// GENERATED FROM schema/macro.schema.yaml — DO NOT EDIT BY HAND. Re-run \`bun run codegen\` after schema changes.
//
// MacroFormat — Swift Codable types for the macRo .macro bundle format (v1).
//
// This module is the lockstep contract between the Mac app and the (later)
// TS factory pipeline. Spec ref: docs/spec.md > Schema source of truth +
// docs/spec.md > MacroFormat. The generator lives at tools/codegen/.
//
// Threading note (carry from Swift conventions): MacroFormat types are pure
// data with zero UI dependencies. Safe to pass across queues.
`;

/** Convert a schema definition name (already PascalCase) to a Swift type name. */
export function swiftTypeName(name: string): string {
    // Schema $defs are already PascalCase; we keep them 1:1 in Swift.
    return name;
}

/**
 * Convert a JSON-Schema property name to a Swift property name. The schema
 * convention is lowerCamelCase already (`gateKind`, `windowTitleMatch`), so
 * this is currently a passthrough — but the indirection is here so renaming
 * rules can land in one place if the schema convention ever shifts.
 */
export function swiftPropertyName(name: string): string {
    return name;
}

/**
 * Swift reserved words and contextual keywords that need backtick-escaping
 * when used as identifiers. List sourced from The Swift Programming Language
 * (Apple, 2024) — declarations + statements + expression keywords. Some
 * contextual keywords (e.g., `mutating`, `weak`) are usable bare in normal
 * positions, but for safety in case-name context we escape them too.
 */
const SWIFT_RESERVED = new Set<string>([
    // Declarations
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "protocol", "public", "rethrows", "static", "struct",
    "subscript", "typealias", "var",
    // Statements
    "break", "case", "continue", "default", "defer", "do", "else", "fallthrough",
    "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while",
    // Expressions
    "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw",
    "throws", "true", "try",
]);

/**
 * Convert an enum value (e.g., `keyDown`, `pos`, `image-anchored`) to a Swift
 * enum case identifier. Hyphens collapse to camelCase boundaries. Reserved
 * words (e.g., `continue`, `class`) get backtick-escaped.
 */
export function swiftEnumCase(value: string): string {
    if (value.length === 0) return value;
    const parts = value.split(/[-_]/g);
    const camel = parts
        .map((p, i) =>
            i === 0
                ? p.charAt(0).toLowerCase() + p.slice(1)
                : p.charAt(0).toUpperCase() + p.slice(1),
        )
        .join("");
    return SWIFT_RESERVED.has(camel) ? `\`${camel}\`` : camel;
}

/**
 * Indent every line of a multi-line string by `n` levels of 4 spaces.
 * Empty lines stay empty (no trailing whitespace).
 */
export function indent(text: string, level = 1): string {
    const pad = "    ".repeat(level);
    return text
        .split("\n")
        .map((l) => (l.length === 0 ? "" : pad + l))
        .join("\n");
}

/**
 * Split a JSON-Schema description into a Swift /// doc comment, one line per
 * source line, preserving paragraph structure.
 */
export function docComment(description: string | undefined): string {
    if (!description) return "";
    const trimmed = description.trim();
    if (trimmed.length === 0) return "";
    return trimmed
        .split("\n")
        .map((line) => `/// ${line.trimEnd()}`)
        .join("\n");
}

/** Quote a string for emission as a Swift string literal. */
export function swiftStringLiteral(s: string): string {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
