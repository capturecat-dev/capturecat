/**
 * Port of Services/CursorSpringMath.swift `CursorEndBehaviorMath.apply(
 * events:trimEnd:loopToStart:stopAtEnd:)` — end-of-clip cursor behaviours,
 * applied AFTER smoothing + fluid movement (see ./cursorChain.ts):
 *
 * - `loopToStart`: over the final 0.8 s (before `trimEnd`, SOURCE seconds)
 *   the cursor glides back to its first position with a smoothstep ease.
 * - `stopAtEnd`: the cursor freezes at the last sample at/before
 *   `trimEnd − 0.5` for the final 0.5 s.
 * - Loop wins when both are on.
 *
 * Locked to Swift by the `cursorEndBehavior` golden vectors (and `cursorChain`).
 * Swift returns the SAME array on the pass-through paths; the port returns a
 * shallow copy.
 */
import type { CursorEvent } from "../model/types";
import { smax, smin } from "./swift";

/** Loop-to-start glide window, seconds. */
export const loopWindow = 0.8;
/** Stop-at-end freeze window, seconds. */
export const stopWindow = 0.5;

/** `CursorEndBehaviorMath.apply(events:trimEnd:loopToStart:stopAtEnd:)`. */
export function apply(
  events: readonly CursorEvent[],
  trimEnd: number,
  loopToStart: boolean,
  stopAtEnd: boolean,
): CursorEvent[] {
  if (!(loopToStart || stopAtEnd) || events.length === 0) return events.slice();
  const first = events[0];
  if (loopToStart) {
    const window = 0.8;
    const rampStart = trimEnd - window;
    return events.map((event) => {
      if (!(event.timestamp > rampStart)) return event;
      const p = smin(1, smax(0, (event.timestamp - rampStart) / window));
      const eased = p * p * (3 - 2 * p);
      return {
        timestamp: event.timestamp,
        x: event.x + (first.x - event.x) * eased,
        y: event.y + (first.y - event.y) * eased,
        isClick: event.isClick,
      };
    });
  }
  // stopAtEnd
  const freezeStart = trimEnd - 0.5;
  let anchor: CursorEvent | null = null;
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].timestamp <= freezeStart) {
      anchor = events[i];
      break;
    }
  }
  if (anchor === null) return events.slice();
  const a = anchor;
  return events.map((event) => {
    if (!(event.timestamp > freezeStart)) return event;
    return { timestamp: event.timestamp, x: a.x, y: a.y, isClick: event.isClick };
  });
}
