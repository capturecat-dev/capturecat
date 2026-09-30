/**
 * Swift/Foundation semantics of the MCP server's argument handling, so a web
 * tool accepts, rejects and REPORTS a value exactly like the Mac one:
 *
 * - `doubleValue` / `isJSONBool` / `boolValue` / `stringValue` … mirror the
 *   `as?` casts on JSONSerialization values (NSNumber bridging: a JSON 0/1
 *   IS a Bool to Swift, a JSON bool is NOT a Double to `doubleValue`).
 * - `has(args, key)` is Swift's `args[key] != nil` — a JSON `null` counts as
 *   present (it is NSNull, not nil).
 * - `describeValue` is Swift's `"\(value)"` for a JSONSerialization value
 *   (NSNumber prints `%.16g`, a Bool prints 1/0, NSNull prints `<null>`,
 *   arrays/dictionaries print their old-style plist description).
 * - `fmt`, `formatNumber`, `round3` are MCPServer's number formatters.
 * - `charCount` / `prefixChars` count extended grapheme clusters (Swift
 *   `String.count` / `prefix`).
 */
import { formatFixed, srounded } from "../../core/math/swift";
import type { JSONObject } from "./types";

// ── Casts (Swift `as?` on JSONSerialization values) ─────────────────────

/** `args[key] != nil` — present, INCLUDING a JSON null (NSNull). */
export function has(args: JSONObject, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(args, key) && args[key] !== undefined;
}

/** `MCPServer.isJSONBool` — a JSON true/false (CFBoolean). */
export function isJSONBool(value: unknown): boolean {
  return typeof value === "boolean";
}

/** `MCPServer.doubleValue` — any JSON number, never a bool or string. */
export function doubleValue(value: unknown): number | null {
  return typeof value === "number" ? value : null;
}

/** `value as? Bool` — NSNumber bridging: true/false, and the numbers 1/0. */
export function boolValue(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (value === 1) return true;
    if (value === 0) return false;
  }
  return null;
}

/** `value as? String` */
export function stringValue(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

/** `value as? [String: Any]` */
export function objectValue(value: unknown): JSONObject | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as JSONObject) : null;
}

/** `value as? [Any]` */
export function arrayValue(value: unknown): unknown[] | null {
  return Array.isArray(value) ? value : null;
}

/** `value as? [[String: Any]]` — nil unless EVERY element is an object. */
export function objectArrayValue(value: unknown): JSONObject[] | null {
  if (!Array.isArray(value)) return null;
  for (const element of value) if (objectValue(element) === null) return null;
  return value as JSONObject[];
}

/** Swift `UUID(uuidString:)` then `.uuidString` — canonical UPPERCASE or null. */
export function uuidValue(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value)
    ? value.toUpperCase()
    : null;
}

// ── Strings (grapheme clusters, CharacterSet trimming) ───────────────────

let segmenter: Intl.Segmenter | null = null;

/** Swift `Array(string)` — extended grapheme clusters. */
export function graphemes(s: string): string[] {
  // Pure ASCII without CR/LF pairs: one cluster per code unit (fast path).
  if (/^[\x00-\x09\x0b\x0c\x0e-\x7f]*$/.test(s)) return s.split("");
  segmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" });
  return Array.from(segmenter.segment(s), (part) => part.segment);
}

/** Swift `String.count` */
export function charCount(s: string): number {
  return graphemes(s).length;
}

/** Swift `String(s.prefix(n))` */
export function prefixChars(s: string, n: number): string {
  const parts = graphemes(s);
  return parts.length <= n ? s : parts.slice(0, n).join("");
}

/** `trimmingCharacters(in: .whitespaces)` — Unicode Zs + TAB. */
export function trimWhitespaces(s: string): string {
  return s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)` — Z*, TAB, LF…CR, NEL. */
export function trimWhitespacesAndNewlines(s: string): string {
  return s.replace(/^[\p{Z}\t\n\v\f\r\u0085]+|[\p{Z}\t\n\v\f\r\u0085]+$/gu, "");
}

// ── Number formatting ───────────────────────────────────────────────────

/** `MCPServer.round3` — 3 decimals, ties away from zero; non-finite → 0. */
export function round3(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return srounded(value * 1000) / 1000;
}

/** `MCPServer.fmt` — `%.3f` with trailing zeros (and a bare point) stripped. */
export function fmt(value: number): string {
  if (!Number.isFinite(value)) return "∞";
  return formatFixed(value, 3).replace(/\.?0+$/, "");
}

/** `MCPServer.formatNumber` — `String(Int(v))` when integral, else `String(v)`. */
export function formatNumber(value: number): string {
  if (Number.isFinite(value) && value === srounded(value)) return BigInt(value).toString();
  return swiftDoubleDescription(value);
}

/**
 * Swift `String(describing: Double)` — the shortest round-trip digits,
 * exponential below 1e-4 (`1e-05`, `1.5e-07`). (Every non-integral Double is
 * below 2^52, so the large-magnitude switch never applies to what the server
 * formats this way.)
 */
export function swiftDoubleDescription(value: number): string {
  if (Number.isNaN(value)) return "nan";
  if (!Number.isFinite(value)) return value > 0 ? "inf" : "-inf";
  if (value === 0) return Object.is(value, -0) ? "-0.0" : "0.0";
  const sign = value < 0 ? "-" : "";
  const [mantissa, expText] = Math.abs(value).toExponential().split("e");
  const exponent = Number(expText);
  const digits = mantissa.replace(".", "");
  if (exponent < -4) {
    const body = digits.length > 1 ? `${digits[0]}.${digits.slice(1)}` : digits;
    const abs = Math.abs(exponent);
    return `${sign}${body}e${exponent < 0 ? "-" : "+"}${abs < 10 ? "0" : ""}${abs}`;
  }
  let text: string;
  if (exponent < 0) {
    text = `0.${"0".repeat(-exponent - 1)}${digits}`;
  } else if (digits.length > exponent + 1) {
    text = `${digits.slice(0, exponent + 1)}.${digits.slice(exponent + 1)}`;
  } else {
    text = `${digits}${"0".repeat(exponent + 1 - digits.length)}.0`;
  }
  return sign + text;
}

const float64 = new DataView(new ArrayBuffer(8));

/** |x| = mant · 2^exp exactly. */
function decompose(ax: number): { mant: bigint; exp: number } {
  float64.setFloat64(0, ax);
  const hi = float64.getUint32(0);
  const lo = float64.getUint32(4);
  const biased = (hi >>> 20) & 0x7ff;
  const frac = (BigInt(hi & 0xfffff) << 32n) | BigInt(lo);
  if (biased === 0) return { mant: frac, exp: -1074 };
  return { mant: frac | (1n << 52n), exp: biased - 1075 };
}

/** round-half-even(|x| · 10^k) on the exact binary value. */
function roundScaled(ax: number, k: number): bigint {
  const { mant, exp } = decompose(ax);
  let num = mant;
  let den = 1n;
  if (exp >= 0) num <<= BigInt(exp);
  else den <<= BigInt(-exp);
  if (k >= 0) num *= 10n ** BigInt(k);
  else den *= 10n ** BigInt(-k);
  let q = num / den;
  const twice = (num - q * den) * 2n;
  if (twice > den || (twice === den && (q & 1n) === 1n)) q += 1n;
  return q;
}

/** C `printf("%.<precision>g", x)` (exact binary value, ties to even). */
export function formatG(x: number, precision: number): string {
  if (Number.isNaN(x)) return "nan";
  if (!Number.isFinite(x)) return x > 0 ? "inf" : "-inf";
  const p = Math.max(1, precision);
  const sign = x < 0 || Object.is(x, -0) ? "-" : "";
  const ax = Math.abs(x);
  if (ax === 0) return `${sign}0`;
  const lo = 10n ** BigInt(p - 1);
  const hi = 10n ** BigInt(p);
  let e = Math.floor(Math.log10(ax));
  let n = roundScaled(ax, p - 1 - e);
  for (let guard = 0; guard < 4 && (n >= hi || n < lo); guard++) {
    e += n >= hi ? 1 : -1;
    n = roundScaled(ax, p - 1 - e);
  }
  const strip = (s: string) => (s.includes(".") ? s.replace(/0+$/, "").replace(/\.$/, "") : s);
  if (e < -4 || e >= p) {
    const digits = n.toString();
    const mantissa = strip(`${digits[0]}.${digits.slice(1)}`);
    const abs = Math.abs(e);
    return `${sign}${mantissa}e${e < 0 ? "-" : "+"}${abs < 10 ? "0" : ""}${abs}`;
  }
  return sign + strip(formatFixed(ax, p - 1 - e));
}

// ── `"\(value)"` for JSONSerialization values ─────────────────────────────

/** NSNumber.description: integers exactly, doubles `%.16g`, bools 1/0. */
function describeNumber(value: number): string {
  if (Number.isInteger(value) && Math.abs(value) < 2 ** 63) {
    return Object.is(value, -0) ? "0" : BigInt(value).toString();
  }
  return formatG(value, 16);
}

/** Old-style plist quoting used inside NSArray/NSDictionary descriptions. */
function plistQuoted(text: string): string {
  if (/^[A-Za-z0-9]+$/.test(text)) return text;
  let out = '"';
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    const ch = text[i];
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\r") out += "\\r";
    else if (code < 0x20 || code > 0x7e) out += `\\U${code.toString(16).padStart(4, "0")}`;
    else out += ch;
  }
  return out + '"';
}

/** NSString `compare:` for dictionary keys (canonical decomposition first). */
function compareKeys(a: string, b: string): number {
  const x = a.normalize("NFD");
  const y = b.normalize("NFD");
  return x < y ? -1 : x > y ? 1 : 0;
}

function describeNested(value: unknown, level: number): string {
  const indent = (n: number) => "    ".repeat(n);
  if (Array.isArray(value)) {
    const items = value.map((item) => indent(level + 1) + describeNested(item, level + 1));
    return `${indent(level)}(\n${items.length ? items.join(",\n") + "\n" : ""}${indent(level)})`;
  }
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value as JSONObject).sort(compareKeys);
    const lines = keys.map(
      (key) =>
        `${indent(level + 1)}${plistQuoted(key)} = ${describeNested((value as JSONObject)[key], level + 1)};`,
    );
    return `${indent(level)}{\n${lines.length ? lines.join("\n") + "\n" : ""}${indent(level)}}`;
  }
  return plistQuoted(describeValue(value));
}

/** Swift `"\(value)"` where `value: Any` came from JSONSerialization. */
export function describeValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "boolean") return value ? "1" : "0";
  if (value === null || value === undefined) return "<null>";
  if (typeof value === "number") return describeNumber(value);
  return describeNested(value, 0);
}

// ── Results ──────────────────────────────────────────────────────────────

/** `MCPServer.jsonSafe` — non-finite numbers → 0 (JSONSerialization would
 * refuse them); undefined members dropped. */
export function jsonSafe(value: unknown): unknown {
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  if (Array.isArray(value)) return value.map((v) => (v === undefined ? null : jsonSafe(v)));
  if (value !== null && typeof value === "object") {
    const out: JSONObject = {};
    for (const [k, v] of Object.entries(value as JSONObject)) if (v !== undefined) out[k] = jsonSafe(v);
    return out;
  }
  return value;
}

/** `MCPServer.resultJSON` — compact JSON with sorted keys (what the desktop
 * server sends as the tool's text content). */
export function resultJSON(value: unknown): string {
  const sortKeys = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(sortKeys);
    if (v !== null && typeof v === "object") {
      const out: JSONObject = {};
      for (const key of Object.keys(v as JSONObject).sort()) out[key] = sortKeys((v as JSONObject)[key]);
      return out;
    }
    return v;
  };
  return JSON.stringify(sortKeys(jsonSafe(value)));
}
