/**
 * Port of Views/Editor/ClickRippleOverlay.swift `TapRippleMath` — the looping
 * tap-indicator annotation's deterministic phase (consumed by
 * Services/AnnotationRenderer.swift with `elapsed = currentTime − a.startTime`,
 * SOURCE seconds, never a wall clock — so scrubbing and export agree).
 *
 * Locked to Swift by the `tapRippleProgress` golden vectors. Swift
 * `truncatingRemainder(dividingBy:)` is C `fmod`, which JS `%` implements
 * exactly (sign of the dividend; NaN for ±∞).
 */

/** One tap pulse every `period` seconds. */
export const period = 1.2;
/** The ripple is visible for `rippleDuration` at the start of each cycle. */
export const rippleDuration = 0.45;

/** `TapRippleMath.progress(elapsed:)` — 0…1 within the current cycle, or null
 * while resting (and for negative/NaN elapsed). */
export function progress(elapsed: number): number | null {
  if (!(elapsed >= 0)) return null;
  const phase = elapsed % period;
  if (!(phase <= rippleDuration)) return null;
  return phase / rippleDuration;
}
