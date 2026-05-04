// schema.ts — typed view over the parsed schema YAML.
//
// We don't aim for a full JSON Schema implementation; we only model the
// subset that macro.schema.yaml actually uses. New shapes added to the schema
// must be reflected here AND in emit-swift.ts — that's the contract.

export type JsonScalar = "string" | "integer" | "number" | "boolean";
export type JsonContainer = "object" | "array";
export type JsonType = JsonScalar | JsonContainer;

export interface SchemaRef {
    $ref: string;
}

export interface SchemaConst {
    const: string | number | boolean;
}

export interface SchemaPrimitive {
    type: JsonScalar;
    description?: string;
    enum?: readonly (string | number)[];
    pattern?: string;
    format?: string;
    minimum?: number;
    maximum?: number;
}

export interface SchemaArray {
    type: "array";
    description?: string;
    items: SchemaNode;
    minItems?: number;
    maxItems?: number;
}

export interface SchemaObject {
    type: "object";
    description?: string;
    properties?: Record<string, SchemaNode>;
    required?: readonly string[];
    additionalProperties?: SchemaNode | boolean;
    oneOf?: readonly SchemaNode[];
}

/**
 * A schema node with no `type` field but containing `oneOf` — used in the
 * schema for the `onFail` / `action` polymorphic-string fields where the
 * value is always a string but matches one of several enum/pattern shapes.
 */
export interface SchemaUnion {
    description?: string;
    oneOf: readonly SchemaNode[];
}

export type SchemaNode =
    | SchemaRef
    | SchemaConst
    | SchemaPrimitive
    | SchemaArray
    | SchemaObject
    | SchemaUnion;

export interface RootSchema {
    $schema?: string;
    $id?: string;
    title?: string;
    description?: string;
    type: "object";
    properties?: Record<string, SchemaNode>;
    required?: readonly string[];
    additionalProperties?: boolean;
    $defs: Record<string, SchemaNode>;
}

// ---------------------------------------------------------------------------
// Type guards
// ---------------------------------------------------------------------------

export function isRef(n: SchemaNode): n is SchemaRef {
    return typeof (n as SchemaRef).$ref === "string";
}

export function isConst(n: SchemaNode): n is SchemaConst {
    return Object.prototype.hasOwnProperty.call(n, "const");
}

export function isObject(n: SchemaNode): n is SchemaObject {
    if ((n as SchemaObject).type === "object") return true;
    // JSON Schema convention: a node with `properties` (and no other type)
    // is implicitly an object. Our schema's `oneOf` branches under
    // TimelineEvent rely on this — they list `properties` + `required`
    // without restating `type: object`.
    if (
        !("type" in n) &&
        !("$ref" in n) &&
        !("const" in n) &&
        Array.isArray((n as SchemaUnion).oneOf) === false &&
        ((n as SchemaObject).properties !== undefined ||
            (n as SchemaObject).required !== undefined ||
            (n as SchemaObject).additionalProperties !== undefined)
    ) {
        return true;
    }
    return false;
}

export function isArray(n: SchemaNode): n is SchemaArray {
    return (n as SchemaArray).type === "array";
}

export function isPrimitive(n: SchemaNode): n is SchemaPrimitive {
    const t = (n as SchemaPrimitive).type;
    return (
        t === "string" ||
        t === "integer" ||
        t === "number" ||
        t === "boolean"
    );
}

export function isUnion(n: SchemaNode): n is SchemaUnion {
    return (
        !("type" in n) &&
        !("$ref" in n) &&
        !("const" in n) &&
        Array.isArray((n as SchemaUnion).oneOf)
    );
}

/** Resolve a `#/$defs/Foo` ref to its definition name (e.g., `Foo`). */
export function refDefName(ref: SchemaRef): string {
    const m = /^#\/\$defs\/([A-Za-z0-9_]+)$/.exec(ref.$ref);
    if (!m) {
        throw new Error(`Unsupported $ref shape: ${ref.$ref}`);
    }
    return m[1] as string;
}
