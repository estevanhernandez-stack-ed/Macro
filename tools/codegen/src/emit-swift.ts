// emit-swift.ts — translate a parsed RootSchema into Swift Codable types.
//
// Mapping decisions (locked at item 2; revisit only with a logged decision):
//
//   - Each top-level $defs entry becomes one Swift `struct` (Codable, Sendable,
//     Equatable, Hashable) — UNLESS it's a discriminated union (oneOf where
//     every branch fixes a `kind` const). Those become a Swift `enum` with
//     associated-value cases + custom Codable.
//
//   - Required-vs-optional: if a property name appears in the object's
//     `required` array, it's non-optional in Swift; otherwise it's `?`.
//
//   - Polymorphic strings (oneOf of string-enum + string-pattern, like
//     `gate.onFail` and `stopOn.action`) are emitted as a typed Swift enum
//     with a `.literal(Literal)` case + a `.subInvocation(name: String)` case.
//
//   - Inline anonymous objects (e.g., `recordedResolution` inside Target,
//     or `between` inside ScheduleWindow) become nested Swift structs whose
//     name is the parent type + property name PascalCased. This keeps
//     names predictable and the Swift surface flat-ish.
//
//   - Inline anonymous arrays-of-objects (the `bindings` array inside
//     Requires) get a synthesized item-type name — same scheme.

import {
    SWIFT_HEADER,
    docComment,
    indent,
    swiftEnumCase,
    swiftPropertyName,
    swiftTypeName,
} from "./shared.ts";
import type {
    RootSchema,
    SchemaArray,
    SchemaNode,
    SchemaObject,
    SchemaPrimitive,
    SchemaUnion,
} from "./schema.ts";
import {
    isArray,
    isConst,
    isObject,
    isPrimitive,
    isRef,
    isUnion,
    refDefName,
} from "./schema.ts";

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

export function emitSwift(schema: RootSchema): string {
    const ctx = new EmitContext();

    // Emit the top-level Manifest+Timeline wrapper that the schema describes
    // at the root. This represents the LOGICAL bundle (manifest + timeline
    // pair) — used in tests and round-tripping. On disk, manifest and
    // timeline live in separate files; the Swift `MacroBundle` domain type
    // (item 3) handles file IO and produces this Codable shape.
    ctx.emitRootBundle(schema);

    // Each $def → one Swift type.
    for (const [name, def] of Object.entries(schema.$defs)) {
        ctx.emitDef(name, def);
    }

    return ctx.render();
}

// ---------------------------------------------------------------------------
// Internal: emission context (collects type sources, header, footer)
// ---------------------------------------------------------------------------

class EmitContext {
    private parts: string[] = [];

    emitRootBundle(schema: RootSchema): void {
        const lines: string[] = [];
        if (schema.title || schema.description) {
            const desc = [schema.title, schema.description]
                .filter(Boolean)
                .join("\n");
            const dc = docComment(desc);
            if (dc) lines.push(dc);
        }
        lines.push(`/// Top-level logical bundle: \`manifest.yaml\` + \`timeline.yaml\` paired.`);
        lines.push(`/// On disk these are two files; this struct represents them as a single`);
        lines.push(`/// Codable value for tests and in-memory round-trips.`);
        lines.push(`public struct MacroBundleData: Codable, Sendable, Equatable, Hashable {`);
        lines.push(`    public let manifest: Manifest`);
        lines.push(`    public let timeline: Timeline`);
        lines.push(``);
        lines.push(`    public init(manifest: Manifest, timeline: Timeline) {`);
        lines.push(`        self.manifest = manifest`);
        lines.push(`        self.timeline = timeline`);
        lines.push(`    }`);
        lines.push(`}`);
        this.parts.push(lines.join("\n"));
    }

    emitDef(name: string, def: SchemaNode): void {
        const swiftName = swiftTypeName(name);

        if (isObject(def)) {
            // Discriminated union? — the load-bearing case.
            if (isDiscriminatedKindUnion(def)) {
                this.parts.push(emitDiscriminatedEnum(swiftName, def));
                return;
            }
            this.parts.push(emitStruct(swiftName, def));
            return;
        }

        // Top-level non-object $def — none in v1, but reachable shape.
        // Fall back to a typealias.
        const inline = swiftInlineType(def, swiftName);
        this.parts.push(`public typealias ${swiftName} = ${inline}`);
    }

    render(): string {
        const banner = SWIFT_HEADER;
        const importLine = `import Foundation\n`;
        const body = this.parts.join("\n\n");
        return `${banner}\n${importLine}\n${body}\n`;
    }
}

// ---------------------------------------------------------------------------
// Discriminated-union detection
// ---------------------------------------------------------------------------

/**
 * A schema object is a discriminated-kind union if it has a `oneOf` array
 * AND every branch is an object whose `kind` property is a const string.
 */
function isDiscriminatedKindUnion(obj: SchemaObject): boolean {
    if (!obj.oneOf || obj.oneOf.length === 0) return false;
    for (const branch of obj.oneOf) {
        if (!isObject(branch)) return false;
        const props = branch.properties;
        if (!props) return false;
        const kindProp = props["kind"];
        if (!kindProp) return false;
        if (!isConst(kindProp)) return false;
        if (typeof kindProp.const !== "string") return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Struct emission (objects WITHOUT a discriminated `oneOf`)
// ---------------------------------------------------------------------------

interface NestedType {
    name: string;
    source: string;
}

function emitStruct(typeName: string, obj: SchemaObject): string {
    const nested: NestedType[] = [];
    const props = obj.properties ?? {};
    const required = new Set(obj.required ?? []);

    const propLines: string[] = [];
    const initParams: string[] = [];
    const initAssigns: string[] = [];

    for (const [propName, propSchema] of Object.entries(props)) {
        const isRequired = required.has(propName);
        const swiftPropName = swiftPropertyName(propName);
        const { swiftType, nestedSources } = swiftTypeForProp(
            propSchema,
            typeName,
            propName,
        );
        nested.push(...nestedSources);
        const finalType = isRequired ? swiftType : `${swiftType}?`;

        const dc = docComment(getDescription(propSchema));
        if (dc) propLines.push(indent(dc, 1));
        propLines.push(`    public let ${swiftPropName}: ${finalType}`);

        const defaultValue = isRequired ? "" : " = nil";
        initParams.push(`${swiftPropName}: ${finalType}${defaultValue}`);
        initAssigns.push(`        self.${swiftPropName} = ${swiftPropName}`);
    }

    const lines: string[] = [];
    const td = docComment(obj.description);
    if (td) lines.push(td);
    lines.push(`public struct ${typeName}: Codable, Sendable, Equatable, Hashable {`);

    // Nested types FIRST so they're visible to the field declarations below.
    if (nested.length > 0) {
        for (const n of nested) {
            lines.push(indent(n.source, 1));
            lines.push("");
        }
    }

    if (propLines.length > 0) {
        lines.push(...propLines);
        lines.push("");
        lines.push(`    public init(`);
        lines.push(
            initParams.map((p, i) =>
                i === initParams.length - 1
                    ? `        ${p}`
                    : `        ${p},`,
            ).join("\n"),
        );
        lines.push(`    ) {`);
        lines.push(...initAssigns);
        lines.push(`    }`);
    } else {
        lines.push(`    public init() {}`);
    }

    lines.push(`}`);
    return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Discriminated-enum emission (the load-bearing TimelineEvent case)
// ---------------------------------------------------------------------------

function emitDiscriminatedEnum(typeName: string, obj: SchemaObject): string {
    // Common (always-present) properties — e.g., `t` on TimelineEvent —
    // are declared at the top of the object alongside `kind`. Each branch's
    // properties exclude `kind` itself; everything else (including the common
    // properties from the parent object's `properties` map, MINUS `kind`) is
    // shared metadata that lives on every case.
    const commonProps = obj.properties ?? {};
    const sharedFields: { name: string; schema: SchemaNode; required: boolean }[] = [];
    const requiredSet = new Set(obj.required ?? []);
    for (const [pName, pSchema] of Object.entries(commonProps)) {
        if (pName === "kind") continue;
        sharedFields.push({
            name: pName,
            schema: pSchema,
            required: requiredSet.has(pName),
        });
    }

    interface Branch {
        kindValue: string;
        caseName: string;
        payloadStructName: string;
        payloadFields: { name: string; schema: SchemaNode; required: boolean }[];
        description?: string;
    }

    const branches: Branch[] = [];
    const branchNested: NestedType[] = [];

    for (const branch of obj.oneOf!) {
        if (!isObject(branch)) continue;
        const branchProps = branch.properties ?? {};
        const branchRequired = new Set(branch.required ?? []);
        const kindProp = branchProps["kind"];
        if (!kindProp || !isConst(kindProp) || typeof kindProp.const !== "string") {
            continue;
        }
        const kindValue = kindProp.const;
        const caseName = swiftEnumCase(kindValue);
        const payloadStructName = `${typeName}${capitalize(caseName)}Payload`;

        const payloadFields: Branch["payloadFields"] = [];

        // Each branch contributes its own fields PLUS the shared fields.
        for (const sf of sharedFields) {
            payloadFields.push(sf);
        }
        for (const [pName, pSchema] of Object.entries(branchProps)) {
            if (pName === "kind") continue;
            // Avoid duplicating shared field if the branch happens to redeclare it.
            if (sharedFields.some((sf) => sf.name === pName)) continue;
            payloadFields.push({
                name: pName,
                schema: pSchema,
                required: branchRequired.has(pName),
            });
        }

        branches.push({
            kindValue,
            caseName,
            payloadStructName,
            payloadFields,
            description: branch.description,
        });
    }

    // Build the enum source.
    const lines: string[] = [];
    const td = docComment(obj.description);
    if (td) lines.push(td);

    lines.push(`public enum ${typeName}: Codable, Sendable, Equatable, Hashable {`);

    // Emit nested payload structs (one per case) as nested types in the enum.
    for (const b of branches) {
        const dc = docComment(b.description);
        if (dc) lines.push(indent(dc, 1));
        lines.push(indent(emitPayloadStruct(b.payloadStructName, b.payloadFields, typeName, branchNested), 1));
        lines.push(``);
    }

    // Surface any deeper nested types pulled out of payload fields.
    for (const n of branchNested) {
        lines.push(indent(n.source, 1));
        lines.push(``);
    }

    // Cases.
    for (const b of branches) {
        lines.push(`    case ${b.caseName}(${b.payloadStructName})`);
    }
    lines.push(``);

    // Discriminator-keyed Codable container.
    lines.push(`    private enum DiscriminatorKey: String, CodingKey {`);
    lines.push(`        case kind`);
    lines.push(`    }`);
    lines.push(``);
    lines.push(`    private enum KindValue: String, Codable {`);
    for (const b of branches) {
        lines.push(`        case ${b.caseName} = ${JSON.stringify(b.kindValue)}`);
    }
    lines.push(`    }`);
    lines.push(``);

    // init(from:) — read the discriminator via keyed container, then decode
    // the payload struct from the same decoder. The payload's default Codable
    // reads its own keys at the same level (and the extra `kind` key is
    // simply ignored by the payload's decoder).
    // Type names are FULLY QUALIFIED (`Swift.Decoder` / `Swift.Encoder`) so
    // a consumer module that defines its own `Encoder` or `Decoder` type
    // (e.g., AVFoundation `Encoder` wrapper) doesn't shadow the stdlib
    // protocol and break codegen-output compilation.
    lines.push(`    public init(from decoder: Swift.Decoder) throws {`);
    lines.push(`        let disc = try decoder.container(keyedBy: DiscriminatorKey.self)`);
    lines.push(`        let kind = try disc.decode(KindValue.self, forKey: .kind)`);
    lines.push(`        switch kind {`);
    for (const b of branches) {
        lines.push(`        case .${b.caseName}:`);
        lines.push(`            self = .${b.caseName}(try ${b.payloadStructName}(from: decoder))`);
    }
    lines.push(`        }`);
    lines.push(`    }`);
    lines.push(``);

    // encode(to:) — encode the payload first (which opens a keyed container
    // for its own fields), then re-open a keyed container with the
    // discriminator key and write `kind`. Multiple keyed-container writes
    // on the same encoder merge into the same underlying dictionary.
    lines.push(`    public func encode(to encoder: Swift.Encoder) throws {`);
    lines.push(`        switch self {`);
    for (const b of branches) {
        lines.push(`        case .${b.caseName}(let payload):`);
        lines.push(`            try payload.encode(to: encoder)`);
        lines.push(`            var disc = encoder.container(keyedBy: DiscriminatorKey.self)`);
        lines.push(`            try disc.encode(KindValue.${b.caseName}, forKey: .kind)`);
    }
    lines.push(`        }`);
    lines.push(`    }`);

    lines.push(`}`);
    return lines.join("\n");
}

/** Emit a plain Codable struct used as a case payload inside an enum. */
function emitPayloadStruct(
    name: string,
    fields: { name: string; schema: SchemaNode; required: boolean }[],
    parentTypeName: string,
    nestedAccumulator: NestedType[],
): string {
    const fieldLines: string[] = [];
    const initParams: string[] = [];
    const initAssigns: string[] = [];
    for (const f of fields) {
        const { swiftType, nestedSources } = swiftTypeForProp(
            f.schema,
            parentTypeName,
            f.name,
        );
        nestedAccumulator.push(...nestedSources);
        const finalType = f.required ? swiftType : `${swiftType}?`;
        const dc = docComment(getDescription(f.schema));
        if (dc) fieldLines.push(dc);
        fieldLines.push(`public let ${swiftPropertyName(f.name)}: ${finalType}`);
        const dflt = f.required ? "" : " = nil";
        initParams.push(`${swiftPropertyName(f.name)}: ${finalType}${dflt}`);
        initAssigns.push(`    self.${swiftPropertyName(f.name)} = ${swiftPropertyName(f.name)}`);
    }
    const inner: string[] = [];
    inner.push(`public struct ${name}: Codable, Sendable, Equatable, Hashable {`);
    if (fieldLines.length > 0) {
        for (const l of fieldLines) inner.push(indent(l, 1));
        inner.push(``);
        inner.push(`    public init(`);
        inner.push(
            initParams.map((p, i) =>
                i === initParams.length - 1
                    ? `        ${p}`
                    : `        ${p},`,
            ).join("\n"),
        );
        inner.push(`    ) {`);
        for (const a of initAssigns) inner.push(`    ${a}`);
        inner.push(`    }`);
    } else {
        inner.push(`    public init() {}`);
    }
    inner.push(`}`);
    return inner.join("\n");
}

// ---------------------------------------------------------------------------
// Type mapping for properties
// ---------------------------------------------------------------------------

interface SwiftTypeResult {
    swiftType: string;
    nestedSources: NestedType[];
}

function swiftTypeForProp(
    node: SchemaNode,
    parentTypeName: string,
    propName: string,
): SwiftTypeResult {
    if (isRef(node)) {
        return { swiftType: refDefName(node), nestedSources: [] };
    }

    if (isPrimitive(node)) {
        // Primitive with `enum` becomes a nested string-raw enum.
        if (node.type === "string" && node.enum && node.enum.length > 0) {
            const enumName = synthName(parentTypeName, propName);
            const source = emitStringEnum(enumName, node.enum as readonly string[], node.description);
            return {
                swiftType: enumName,
                nestedSources: [{ name: enumName, source }],
            };
        }
        return {
            swiftType: swiftPrimitive(node),
            nestedSources: [],
        };
    }

    if (isArray(node)) {
        const elt = swiftTypeForProp(node.items, parentTypeName, propName + "Item");
        return {
            swiftType: `[${elt.swiftType}]`,
            nestedSources: elt.nestedSources,
        };
    }

    if (isObject(node)) {
        // Inline anonymous object — synthesize a nested type.
        const additional = node.additionalProperties;
        if (additional && typeof additional !== "boolean") {
            // Dictionary-style: { [key]: SchemaNode }
            const valueResult = swiftTypeForProp(additional, parentTypeName, propName + "Value");
            return {
                swiftType: `[String: ${valueResult.swiftType}]`,
                nestedSources: valueResult.nestedSources,
            };
        }
        const synthesized = synthName(parentTypeName, propName);
        const source = emitStruct(synthesized, node);
        return {
            swiftType: synthesized,
            nestedSources: [{ name: synthesized, source }],
        };
    }

    if (isUnion(node)) {
        // Polymorphic-string union (literal-enum + sub:<name> pattern).
        // Used for TimelineEvent.gate.onFail and StopOnTrigger.action.
        const result = emitPolymorphicStringUnion(parentTypeName, propName, node);
        if (result) return result;
        // Fallback: free-form String.
        return { swiftType: "String", nestedSources: [] };
    }

    // Fallback — should be unreachable for v1 schema.
    return { swiftType: "String", nestedSources: [] };
}

function swiftPrimitive(node: SchemaPrimitive): string {
    switch (node.type) {
        case "string":
            return "String";
        case "integer":
            return "Int";
        case "number":
            return "Double";
        case "boolean":
            return "Bool";
    }
}

/** Synthesize a nested type name from parent + property. */
function synthName(parent: string, prop: string): string {
    return `${parent}${capitalize(prop)}`;
}

function capitalize(s: string): string {
    if (s.length === 0) return s;
    return s.charAt(0).toUpperCase() + s.slice(1);
}

function emitStringEnum(
    name: string,
    cases: readonly string[],
    description?: string,
): string {
    const lines: string[] = [];
    const dc = docComment(description);
    if (dc) lines.push(dc);
    lines.push(`public enum ${name}: String, Codable, Sendable, Equatable, Hashable, CaseIterable {`);
    for (const c of cases) {
        const caseName = swiftEnumCase(c);
        if (caseName === c) {
            lines.push(`    case ${caseName}`);
        } else {
            lines.push(`    case ${caseName} = ${JSON.stringify(c)}`);
        }
    }
    lines.push(`}`);
    return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Polymorphic-string unions (onFail, action)
// ---------------------------------------------------------------------------

/**
 * Detects the schema shape:
 *
 *     oneOf:
 *       - type: string
 *         enum: [literal1, literal2]
 *       - type: string
 *         pattern: "^sub:[…]"
 *
 * Emits a Swift enum:
 *
 *     public enum FooBar: Codable, Sendable, Equatable, Hashable {
 *         case literal(Literal)
 *         case subInvocation(name: String)
 *         public enum Literal: String, Codable, ... { case literal1; case literal2 }
 *     }
 *
 * with custom Codable that decodes a single string value and dispatches on
 * `sub:` prefix.
 */
function emitPolymorphicStringUnion(
    parentTypeName: string,
    propName: string,
    node: SchemaUnion,
): SwiftTypeResult | null {
    let literalEnum: SchemaPrimitive | null = null;
    let hasSubPattern = false;

    for (const branch of node.oneOf) {
        if (isPrimitive(branch) && branch.type === "string") {
            if (branch.enum && branch.enum.length > 0) {
                literalEnum = branch;
            } else if (branch.pattern && branch.pattern.includes("sub:")) {
                hasSubPattern = true;
            }
        }
    }

    if (!literalEnum || !hasSubPattern) return null;

    const enumName = synthName(parentTypeName, propName);
    const literalEnumName = `Literal`;
    const literalCases = literalEnum.enum as readonly string[];

    const lines: string[] = [];
    const dc = docComment(node.description);
    if (dc) lines.push(dc);
    lines.push(`public enum ${enumName}: Codable, Sendable, Equatable, Hashable {`);
    lines.push(``);
    lines.push(`    public enum ${literalEnumName}: String, Codable, Sendable, Equatable, Hashable, CaseIterable {`);
    for (const c of literalCases) {
        const caseName = swiftEnumCase(c);
        if (caseName === c) {
            lines.push(`        case ${caseName}`);
        } else {
            lines.push(`        case ${caseName} = ${JSON.stringify(c)}`);
        }
    }
    lines.push(`    }`);
    lines.push(``);
    lines.push(`    case literal(${literalEnumName})`);
    lines.push(`    /// Sub-macro invocation — \`sub:<name>\` form. \`name\` is the bare identifier.`);
    lines.push(`    case subInvocation(name: String)`);
    lines.push(``);
    // Fully qualified `Swift.Decoder` / `Swift.Encoder` so consumer modules
    // can define their own `Encoder`/`Decoder` types without shadowing.
    lines.push(`    public init(from decoder: Swift.Decoder) throws {`);
    lines.push(`        let single = try decoder.singleValueContainer()`);
    lines.push(`        let raw = try single.decode(String.self)`);
    lines.push(`        if raw.hasPrefix("sub:") {`);
    lines.push(`            let name = String(raw.dropFirst(4))`);
    lines.push(`            self = .subInvocation(name: name)`);
    lines.push(`            return`);
    lines.push(`        }`);
    lines.push(`        if let lit = ${literalEnumName}(rawValue: raw) {`);
    lines.push(`            self = .literal(lit)`);
    lines.push(`            return`);
    lines.push(`        }`);
    lines.push(`        throw DecodingError.dataCorruptedError(`);
    lines.push(`            in: single,`);
    lines.push(`            debugDescription: "Unrecognized ${enumName} value: \\(raw)"`);
    lines.push(`        )`);
    lines.push(`    }`);
    lines.push(``);
    lines.push(`    public func encode(to encoder: Swift.Encoder) throws {`);
    lines.push(`        var single = encoder.singleValueContainer()`);
    lines.push(`        switch self {`);
    lines.push(`        case .literal(let lit):`);
    lines.push(`            try single.encode(lit.rawValue)`);
    lines.push(`        case .subInvocation(let name):`);
    lines.push(`            try single.encode("sub:\\(name)")`);
    lines.push(`        }`);
    lines.push(`    }`);
    lines.push(`}`);

    return {
        swiftType: enumName,
        nestedSources: [{ name: enumName, source: lines.join("\n") }],
    };
}

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

function getDescription(node: SchemaNode): string | undefined {
    if (isRef(node)) return undefined;
    if (isConst(node)) return undefined;
    return (node as { description?: string }).description;
}

/** Inline-resolve a schema node to a Swift type expression (no nested types). */
function swiftInlineType(node: SchemaNode, fallbackName: string): string {
    if (isRef(node)) return refDefName(node);
    if (isPrimitive(node)) return swiftPrimitive(node);
    if (isArray(node)) {
        return `[${swiftInlineType(node.items, fallbackName + "Item")}]`;
    }
    return fallbackName;
}
