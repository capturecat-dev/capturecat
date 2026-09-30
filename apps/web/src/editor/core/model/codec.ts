/**
 * Decoding primitives that reproduce Swift's `JSONDecoder` +
 * `KeyedDecodingContainer` semantics exactly, so `parseProject` accepts,
 * rejects and defaults precisely what the Mac app does.
 *
 * Swift semantics mirrored here:
 * - `decode(T, forKey:)`: key missing → keyNotFound; JSON null → valueNotFound;
 *   wrong JSON type → typeMismatch. All THROW (the whole project fails to load).
 * - `decodeIfPresent(T, forKey:)`: missing key OR null → nil; a present value
 *   of the wrong type still THROWS.
 * - `(try? c.decodeIfPresent(...)) ?? default` ("lenient"): any failure,
 *   missing or null → default.
 * - Double: any JSON number. Int: an integral JSON number. Bool: only JSON
 *   true/false (never 0/1). String: only JSON strings.
 * - UUID: `UUID(uuidString:)` — 8-4-4-4-12 hex, case-insensitive; re-encoded
 *   UPPERCASE (so we normalise to uppercase on decode).
 * - Date (default `.deferredToDate`): a JSON number, seconds since 2001-01-01.
 * - URL (JSONDecoder special case): a string `URL(string:)` accepts (non-empty).
 * - Enum: a JSON string that is one of the raw values, else dataCorrupted.
 * - CGPoint: an unkeyed container `[x, y]` (extra elements ignored).
 */
import type { ExtraKeys, Point } from "./types";

export class ProjectDecodeError extends Error {
  readonly codingPath: string;
  constructor(codingPath: string, message: string) {
    super(`${codingPath}: ${message}`);
    this.name = "ProjectDecodeError";
    this.codingPath = codingPath;
  }
}

export type JSONObject = Record<string, unknown>;

export function isObject(v: unknown): v is JSONObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** A value decoder: returns the decoded value or throws ProjectDecodeError. */
export type Decode<T> = (value: unknown, path: string) => T;

export const dDouble: Decode<number> = (v, path) => {
  if (typeof v !== "number" || !Number.isFinite(v)) throw new ProjectDecodeError(path, "expected a number");
  return v;
};

export const dInt: Decode<number> = (v, path) => {
  if (typeof v !== "number" || !Number.isInteger(v)) throw new ProjectDecodeError(path, "expected an integer");
  return v;
};

export const dBool: Decode<boolean> = (v, path) => {
  if (typeof v !== "boolean") throw new ProjectDecodeError(path, "expected a bool");
  return v;
};

export const dString: Decode<string> = (v, path) => {
  if (typeof v !== "string") throw new ProjectDecodeError(path, "expected a string");
  return v;
};

export const dUUID: Decode<string> = (v, path) => {
  if (typeof v !== "string") throw new ProjectDecodeError(path, "expected a UUID string");
  if (!UUID_RE.test(v)) throw new ProjectDecodeError(path, "invalid UUID string");
  return v.toUpperCase();
};

/** Swift `Date` with the default strategy: seconds since the 2001 reference date. */
export const dDate: Decode<number> = dDouble;

export const dURL: Decode<string> = (v, path) => {
  if (typeof v !== "string") throw new ProjectDecodeError(path, "expected a URL string");
  if (v.length === 0) throw new ProjectDecodeError(path, "invalid URL string");
  return canonicalURLString(v);
};

// RFC 3986 character classes (as Foundation's URLComponents allowed sets).
const UNRESERVED = "A-Za-z0-9\\-._~";
const SUB_DELIMS = "!$&'()*+,;=";
const PCHAR = `${UNRESERVED}${SUB_DELIMS}:@`;
const PATH_ALLOWED = new RegExp(`[${PCHAR}/]`);
const QUERY_ALLOWED = new RegExp(`[${PCHAR}/?]`);
const FRAGMENT_ALLOWED = QUERY_ALLOWED;
const AUTHORITY_ALLOWED = new RegExp(`[${UNRESERVED}${SUB_DELIMS}:@\\[\\]]`);

function encodeComponent(s: string, allowed: RegExp): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "%" && /^[0-9A-Fa-f]{2}$/.test(s.slice(i + 1, i + 3))) {
      out += ch;
      continue;
    }
    if (allowed.test(ch)) {
      out += ch;
      continue;
    }
    const cp = s.codePointAt(i)!;
    if (cp > 0xffff) i++;
    for (const b of new TextEncoder().encode(String.fromCodePoint(cp))) {
      out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
    }
  }
  return out;
}

/**
 * `URL(string: s)!.absoluteString` for the strings project.json can hold.
 * Since macOS 14, `URL(string:)` percent-encodes characters that are invalid
 * in their URL component instead of failing ("a b" → "a%20b", a second "#"
 * → "%23", "[" in a path → "%5B"), so a URL written back by Swift is the
 * encoded form. Swift-written URLs are already valid and pass through
 * unchanged. Components are split per RFC 3986 (scheme, //authority, path,
 * ?query, #fragment) and each is encoded with its allowed set; existing
 * `%XX` escapes are kept. Locked by the `projectDecode` "weirdURL" cases.
 */
export function canonicalURLString(s: string): string {
  let rest = s;
  let out = "";
  const scheme = /^[A-Za-z][A-Za-z0-9+.-]*:/.exec(rest);
  if (scheme) {
    out += scheme[0];
    rest = rest.slice(scheme[0].length);
  }
  if (rest.startsWith("//")) {
    const end = rest.slice(2).search(/[/?#]/);
    const authority = end < 0 ? rest.slice(2) : rest.slice(2, 2 + end);
    out += `//${encodeComponent(authority, AUTHORITY_ALLOWED)}`;
    rest = end < 0 ? "" : rest.slice(2 + end);
  }
  const hash = rest.indexOf("#");
  const beforeHash = hash < 0 ? rest : rest.slice(0, hash);
  const fragment = hash < 0 ? null : rest.slice(hash + 1);
  const q = beforeHash.indexOf("?");
  const pathPart = q < 0 ? beforeHash : beforeHash.slice(0, q);
  const query = q < 0 ? null : beforeHash.slice(q + 1);
  out += encodeComponent(pathPart, PATH_ALLOWED);
  if (query !== null) out += `?${encodeComponent(query, QUERY_ALLOWED)}`;
  if (fragment !== null) out += `#${encodeComponent(fragment, FRAGMENT_ALLOWED)}`;
  return out;
}

export function dEnum<T extends string>(values: ReadonlyArray<T>): Decode<T> {
  return (v, path) => {
    if (typeof v !== "string") throw new ProjectDecodeError(path, "expected an enum raw value string");
    if (!(values as ReadonlyArray<string>).includes(v)) {
      throw new ProjectDecodeError(path, `cannot initialize from invalid raw value ${JSON.stringify(v)}`);
    }
    return v as T;
  };
}

/** CGPoint's Codable: unkeyed `[x, y]`. */
export const dCGPoint: Decode<Point> = (v, path) => {
  if (!Array.isArray(v)) throw new ProjectDecodeError(path, "expected [x, y]");
  if (v.length < 2) throw new ProjectDecodeError(path, "unkeyed container is at end");
  return { x: dDouble(v[0], `${path}[0]`), y: dDouble(v[1], `${path}[1]`) };
};

export function dArray<T>(element: Decode<T>): Decode<T[]> {
  return (v, path) => {
    if (!Array.isArray(v)) throw new ProjectDecodeError(path, "expected an array");
    return v.map((item, i) => element(item, `${path}[${i}]`));
  };
}

/** Keyed container over one JSON object — mirrors KeyedDecodingContainer. */
export class Keyed {
  readonly obj: JSONObject;
  readonly path: string;
  private readonly known: ReadonlySet<string>;

  constructor(value: unknown, path: string, codingKeys: readonly string[]) {
    if (!isObject(value)) throw new ProjectDecodeError(path, "expected a keyed container (JSON object)");
    this.obj = value;
    this.path = path;
    this.known = new Set(codingKeys);
  }

  private keyPath(key: string): string {
    return this.path ? `${this.path}.${key}` : key;
  }

  /** `decode(T, forKey:)` */
  decode<T>(key: string, d: Decode<T>): T {
    if (!Object.prototype.hasOwnProperty.call(this.obj, key)) {
      throw new ProjectDecodeError(this.keyPath(key), "key not found");
    }
    const v = this.obj[key];
    if (v === null) throw new ProjectDecodeError(this.keyPath(key), "value not found (null)");
    return d(v, this.keyPath(key));
  }

  /** `decodeIfPresent(T, forKey:)` — undefined when missing or null. */
  decodeIfPresent<T>(key: string, d: Decode<T>): T | undefined {
    if (!Object.prototype.hasOwnProperty.call(this.obj, key)) return undefined;
    const v = this.obj[key];
    if (v === null) return undefined;
    return d(v, this.keyPath(key));
  }

  /** `(try? decodeIfPresent(T, forKey:))` flattened — undefined on ANY failure. */
  tryDecodeIfPresent<T>(key: string, d: Decode<T>): T | undefined {
    try {
      return this.decodeIfPresent(key, d);
    } catch (e) {
      if (e instanceof ProjectDecodeError) return undefined;
      throw e;
    }
  }

  /** `(try? decode(T, forKey:))` — undefined on ANY failure (incl. missing). */
  tryDecode<T>(key: string, d: Decode<T>): T | undefined {
    try {
      return this.decode(key, d);
    } catch (e) {
      if (e instanceof ProjectDecodeError) return undefined;
      throw e;
    }
  }

  /** Keys this Swift type does not know — preserved verbatim by the web. */
  extra(): ExtraKeys | undefined {
    let out: ExtraKeys | undefined;
    for (const k of Object.keys(this.obj)) {
      if (this.known.has(k)) continue;
      (out ??= {})[k] = this.obj[k];
    }
    return out;
  }
}

/** Attaches `$extra` only when there are unknown keys (keeps objects lean). */
export function withExtra<T extends object>(value: T, extra: ExtraKeys | undefined): T {
  if (extra) (value as T & { $extra?: ExtraKeys }).$extra = extra;
  return value;
}
