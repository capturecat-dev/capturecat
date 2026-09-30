/**
 * `?t=<seconds>` — the editor's one-shot pending seek, the web twin of
 * `AppState.pendingSeekOutputTime` (set by DeepLinkHandler's
 * `capturecat://open-project?id=…&t=…` and by search hits; consumed by
 * EditorShellViewController when the player loads, or late when the editor
 * is already open).
 *
 *   parse:   `if let t = Double(tString), t >= 0` — OUTPUT seconds;
 *   consume: clamp to [0, fullTimeMap.outputDuration] (then the Mac maps it
 *            to SOURCE for the player; the web playhead IS output time).
 */
import type { Project } from "../core/model";
import { fullTimeMap } from "./edits";

/** Swift `Double(String)`: decimal / hex float, inf / infinity / nan — no whitespace. */
const SWIFT_DOUBLE = /^[+-]?(?:(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][+-]?\d+)?|inf|infinity|nan)$/i;

function swiftDouble(s: string): number | null {
  if (!SWIFT_DOUBLE.test(s)) return null;
  const lower = s.toLowerCase();
  const sign = lower.startsWith("-") ? -1 : 1;
  const body = lower.replace(/^[+-]/, "");
  if (body === "inf" || body === "infinity") return sign * Infinity;
  if (body === "nan") return NaN;
  if (body.startsWith("0x")) {
    const m = /^0x([0-9a-f]*)\.?([0-9a-f]*)(?:p([+-]?\d+))?$/.exec(body);
    if (!m) return null;
    const int = m[1] ? parseInt(m[1], 16) : 0;
    const frac = m[2] ? parseInt(m[2], 16) / Math.pow(16, m[2].length) : 0;
    return sign * (int + frac) * Math.pow(2, m[3] ? parseInt(m[3], 10) : 0);
  }
  return Number(s);
}

/**
 * The `t` search value → output seconds, or null when absent / invalid.
 * Accepts the raw string, or the number a JSON-ish search parser already made.
 */
export function parsePendingSeek(raw: unknown): number | null {
  let t: number | null = null;
  if (typeof raw === "number") t = raw;
  else if (typeof raw === "string") t = swiftDouble(raw);
  if (t === null || Number.isNaN(t) || !(t >= 0)) return null;
  return t;
}

/** The output time the playhead lands on (`min(max(0, t), map.outputDuration)`). */
export function pendingSeekOutputTime(project: Project, t: number): number {
  return Math.min(Math.max(0, t), fullTimeMap(project).outputDuration);
}
