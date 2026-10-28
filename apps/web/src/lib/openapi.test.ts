import { describe, expect, it } from "vitest";

import { OPENAPI_DOCUMENT } from "./openapi";

/**
 * Structural lint for the hand-maintained OpenAPI document. It checks the
 * things agent-readiness tooling and LLM function calling depend on — an
 * OpenAPI 3.1 shape, unique camelCase operationIds, a summary + description
 * on every operation, a typed 2xx response, described parameters, and every
 * $ref resolving inside the document. It cannot check that the document is
 * TRUE to the routes; see the header of openapi.ts for the files to re-read.
 */

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };

// The document must survive a JSON round trip unchanged (it is served as JSON).
const doc = JSON.parse(JSON.stringify(OPENAPI_DOCUMENT)) as JsonObject;

const HTTP_METHODS = ["get", "put", "post", "delete", "options", "head", "patch", "trace"] as const;

function isObject(value: Json | undefined): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function obj(value: Json | undefined, where: string): JsonObject {
  if (!isObject(value)) throw new Error(`${where} is not an object`);
  return value;
}

/** Resolve a local JSON pointer ("#/components/schemas/X"), or undefined. */
function resolvePointer(pointer: string): Json | undefined {
  if (!pointer.startsWith("#/")) return undefined;
  let node: Json | undefined = doc;
  for (const raw of pointer.slice(2).split("/")) {
    const key = raw.replace(/~1/g, "/").replace(/~0/g, "~");
    if (Array.isArray(node)) node = node[Number(key)];
    else if (isObject(node)) node = node[key];
    else return undefined;
    if (node === undefined) return undefined;
  }
  return node;
}

/** Follow a $ref chain to the object it names. */
function deref(value: Json | undefined): Json | undefined {
  let node = value;
  for (let hops = 0; isObject(node) && typeof node.$ref === "string"; hops++) {
    if (hops > 10) throw new Error(`$ref cycle at ${node.$ref}`);
    node = resolvePointer(node.$ref);
  }
  return node;
}

function collectRefs(node: Json, path: string, out: Array<{ ref: string; at: string }>): void {
  if (Array.isArray(node)) {
    node.forEach((child, i) => collectRefs(child, `${path}/${i}`, out));
  } else if (isObject(node)) {
    for (const [key, child] of Object.entries(node)) {
      if (key === "$ref" && typeof child === "string") out.push({ ref: child, at: path });
      else collectRefs(child, `${path}/${key}`, out);
    }
  }
}

interface Operation {
  method: string;
  path: string;
  pathItem: JsonObject;
  op: JsonObject;
}

const paths = obj(doc.paths, "paths");
const operations: Operation[] = Object.entries(paths).flatMap(([path, item]) => {
  const pathItem = obj(item, `paths["${path}"]`);
  return HTTP_METHODS.filter((m) => m in pathItem).map((method) => ({
    method,
    path,
    pathItem,
    op: obj(pathItem[method], `${method.toUpperCase()} ${path}`),
  }));
});

describe("OpenAPI document", () => {
  it("has the OpenAPI 3.1 top-level shape", () => {
    expect(doc.openapi).toBe("3.1.0");
    const info = obj(doc.info, "info");
    expect(info.title).toBe("CaptureCat API");
    expect(typeof info.version).toBe("string");
    expect(String(info.description)).toContain("https://capturecat.so/docs");
    expect(String(info.description)).toContain("https://capturecat.so/llms.txt");
    expect(obj(info.contact, "info.contact")).toMatchObject({
      email: "contact@capturecat.so",
      url: "https://capturecat.so",
    });
    expect(doc.servers).toEqual([expect.objectContaining({ url: "https://api.capturecat.so" })]);
    expect(obj(doc.externalDocs, "externalDocs").url).toBe("https://capturecat.so/docs");
    expect(operations.length).toBeGreaterThan(0);
  });

  it("round-trips through JSON unchanged", () => {
    expect(doc).toEqual(OPENAPI_DOCUMENT);
  });

  it("puts every path under /api/", () => {
    for (const path of Object.keys(paths)) {
      expect(path, path).toMatch(/^\/api\//);
    }
  });

  it("gives every operation a unique camelCase operationId, a summary, a description and tags", () => {
    const declaredTags = new Set(
      (doc.tags as Json[]).map((t) => String(obj(t, "tag").name)),
    );
    const seen = new Map<string, string>();
    for (const { method, path, op } of operations) {
      const where = `${method.toUpperCase()} ${path}`;
      expect(typeof op.operationId, where).toBe("string");
      const id = op.operationId as string;
      expect(id, where).toMatch(/^[a-z][A-Za-z0-9]*$/);
      expect(seen.has(id), `${where} reuses operationId ${id} from ${seen.get(id)}`).toBe(false);
      seen.set(id, where);
      expect(String(op.summary ?? "").trim(), `${where} summary`).not.toBe("");
      expect(String(op.description ?? "").trim(), `${where} description`).not.toBe("");
      expect(Array.isArray(op.tags) && op.tags.length > 0, `${where} tags`).toBe(true);
      for (const tag of op.tags as Json[]) {
        expect(declaredTags.has(String(tag)), `${where} uses undeclared tag ${String(tag)}`).toBe(true);
      }
      expect(Array.isArray(op.security), `${where} must state its security explicitly`).toBe(true);
    }
  });

  it("gives every operation a 2xx response with typed content", () => {
    for (const { method, path, op } of operations) {
      const where = `${method.toUpperCase()} ${path}`;
      const responses = obj(op.responses, `${where} responses`);
      const ok = Object.entries(responses).filter(([status]) => /^2\d\d$/.test(status));
      expect(ok.length, `${where} has no 2xx response`).toBeGreaterThan(0);
      const typed = ok.some(([, response]) => {
        const resolved = deref(response);
        if (!isObject(resolved) || !isObject(resolved.content)) return false;
        const media = Object.values(resolved.content);
        return media.length > 0 && media.every((m) => isObject(m) && isObject(m.schema));
      });
      expect(typed, `${where} has no 2xx response with a schema`).toBe(true);
      for (const [status, response] of Object.entries(responses)) {
        const resolved = obj(deref(response), `${where} ${status}`);
        expect(String(resolved.description ?? "").trim(), `${where} ${status} description`).not.toBe("");
      }
    }
  });

  it("resolves every $ref inside the document", () => {
    const refs: Array<{ ref: string; at: string }> = [];
    collectRefs(doc, "#", refs);
    expect(refs.length).toBeGreaterThan(0);
    for (const { ref, at } of refs) {
      expect(ref.startsWith("#/"), `${at} has a non-local $ref ${ref}`).toBe(true);
      expect(resolvePointer(ref), `${at} → ${ref} does not resolve`).toBeDefined();
    }
  });

  it("describes and types every parameter, and declares every path template variable", () => {
    for (const { method, path, pathItem, op } of operations) {
      const where = `${method.toUpperCase()} ${path}`;
      const params = [
        ...((pathItem.parameters as Json[] | undefined) ?? []),
        ...((op.parameters as Json[] | undefined) ?? []),
      ].map((p) => obj(deref(p), `${where} parameter`));

      const keys = new Set<string>();
      for (const p of params) {
        const name = `${where} ${String(p.in)}:${String(p.name)}`;
        expect(typeof p.name, name).toBe("string");
        expect(["query", "header", "path", "cookie"], name).toContain(p.in);
        expect(isObject(p.schema), `${name} has no schema`).toBe(true);
        expect(String(p.description ?? "").trim(), `${name} has no description`).not.toBe("");
        const key = `${String(p.in)}:${String(p.name)}`;
        expect(keys.has(key), `${name} is declared twice`).toBe(false);
        keys.add(key);
      }

      const templated = [...path.matchAll(/\{([^}]+)\}/g)].map((m) => m[1]);
      for (const variable of templated) {
        const declared = params.find((p) => p.in === "path" && p.name === variable);
        expect(declared, `${where} does not declare path parameter ${variable}`).toBeDefined();
        expect(declared?.required, `${where} path parameter ${variable} must be required`).toBe(true);
      }
      for (const p of params.filter((p) => p.in === "path")) {
        expect(templated, `${where} declares unused path parameter ${String(p.name)}`).toContain(p.name);
      }
    }
  });

  it("references only declared security schemes", () => {
    const schemes = obj(obj(doc.components, "components").securitySchemes, "securitySchemes");
    for (const { method, path, op } of operations) {
      for (const requirement of op.security as Json[]) {
        for (const name of Object.keys(obj(requirement, "security requirement"))) {
          expect(name in schemes, `${method.toUpperCase()} ${path} uses unknown scheme ${name}`).toBe(true);
        }
      }
    }
  });
});
