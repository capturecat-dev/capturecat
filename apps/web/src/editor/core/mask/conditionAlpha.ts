/**
 * Producer alpha conditioning (docs/camera-cutout.md §6) — what a mask
 * PRODUCER does to each matte before handing it to the `.ccmask` encoder.
 * The format and the decoder are untouched: this only decides which alpha
 * values get written, so the track compresses (raw mattes shimmer at the edge
 * and flicker ±1–3 levels everywhere, which makes every frame a fresh key —
 * ~12 MB per minute on a real Vision matte at 288 rows; conditioned at the
 * producer resolution below, ~1.5 MB).
 *
 * Twin of apps/macos/CaptureCat/Services/CameraMaskConditioning.swift —
 * integer-exact, same constants, so both producers write identical bytes for
 * identical mattes. Per pixel, with `prev` = the previous frame's CONDITIONED
 * value (none for the first frame):
 *
 *   1. dead zone:  v < deadZone → 0;  v > 255 − deadZone → 255
 *   2. hold:       prev exists and |v − prev| ≤ hold → out = prev
 *   3. quantise:   else out = (level·255 + ⌊(L−1)/2⌋) ÷ (L−1),
 *                  level = (v·(L−1) + 127) ÷ 255   (integer ÷)
 *
 * The hold compares the dead-zoned RAW value with the previous OUTPUT
 * (hysteresis): a pixel only changes level when the matte really moved, so
 * still regions repeat byte-for-byte and the encoder's XOR deltas win.
 */

export interface AlphaConditioningRule {
  /** Values within this of 0 / 255 snap to 0 / 255. 0 = off. */
  deadZone: number;
  /** Output levels across 0…255 (2…256). 256 = off. */
  levels: number;
  /** Keep the previous output when the new value is within this. 0 = off. */
  hold: number;
}

/** THE producer rule both platforms write with (Swift `CameraMaskConditioning.producer`). */
export const PRODUCER_ALPHA_CONDITIONING: Readonly<AlphaConditioningRule> = Object.freeze({
  deadZone: 16,
  levels: 8,
  hold: 32,
});

/** The rule that changes nothing. */
export const NO_ALPHA_CONDITIONING: Readonly<AlphaConditioningRule> = Object.freeze({ deadZone: 0, levels: 256, hold: 0 });

/** Producer mask resolution (§2): 192 rows, width round(192 × aspect) ≤ 341 (16:9 → 341×192). */
export const PRODUCER_MASK_HEIGHT = 192;
export const PRODUCER_MASK_MAX_WIDTH = 341;
/** A key frame at least this often — both producers write 30. */
export const PRODUCER_KEYFRAME_INTERVAL = 30;

/** Twin of Swift `CameraMaskTrack.maskSize(cameraAspect:)`. */
export function producerMaskSize(aspect: number): { width: number; height: number } {
  const a = Number.isFinite(aspect) && aspect > 0 ? aspect : 1;
  const width = Math.round(PRODUCER_MASK_HEIGHT * a);
  return { width: Math.max(1, Math.min(PRODUCER_MASK_MAX_WIDTH, width)), height: PRODUCER_MASK_HEIGHT };
}

/** Quantised value of v (0…255) for `levels` — exact integer arithmetic. */
export function quantizeAlpha(v: number, levels: number): number {
  if (!(levels < 256 && levels >= 2)) return v;
  const steps = levels - 1;
  const level = Math.floor((v * steps + 127) / 255);
  return Math.floor((level * 255 + Math.floor(steps / 2)) / steps);
}

/**
 * Conditions one frame IN PLACE (and returns it). `previous` is the previous
 * frame's conditioned output (same length), or null for the first frame.
 */
export function conditionAlpha(
  alpha: Uint8Array,
  previous: Uint8Array | null,
  rule: Readonly<AlphaConditioningRule> = PRODUCER_ALPHA_CONDITIONING,
): Uint8Array {
  const lo = rule.deadZone;
  const hi = 255 - rule.deadZone;
  const hold = rule.hold;
  const table = new Uint8Array(256);
  for (let v = 0; v < 256; v++) table[v] = quantizeAlpha(v, rule.levels);
  const prev = hold > 0 && previous && previous.length === alpha.length ? previous : null;
  for (let i = 0; i < alpha.length; i++) {
    let v = alpha[i]!;
    if (v < lo) v = 0;
    else if (v > hi) v = 255;
    if (prev) {
      const p = prev[i]!;
      alpha[i] = Math.abs(v - p) <= hold ? p : table[v]!;
    } else {
      alpha[i] = table[v]!;
    }
  }
  return alpha;
}
