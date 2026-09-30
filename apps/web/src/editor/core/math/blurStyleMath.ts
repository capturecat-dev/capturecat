/**
 * Port of apps/macos/CaptureCat/Services/BlurStyleMath.swift — blur-region
 * style math shared by the Mac preview patch pipeline and the exporter: the
 * strength → mosaic block size mapping and the animated-censor grid jitter.
 *
 * Golden-vector units: `blurStyleMath` (pixelScale, quantizedStep,
 * gridJitter, hash01), `regionConstants`, `exportRegionBlur`.
 *
 * Animated pixelate is deterministic from the TIMELINE clock (source seconds):
 * time quantizes to `animationStep` and each step hashes to a grid-phase
 * offset within ±half a block. `pixelScale` is CIPixellate's `inputScale`
 * (block edge in the render space's units — output pixels in the exporter);
 * `gridJitter` is added to CIPixellate's `inputCenter`, which the exporter
 * anchors at the region's CI (Y-UP) origin — see exportRegions.ts.
 */
import type { Point, Size } from "../model/types";
import { sInt, smax, smin } from "./swift";

/** Censor-style cadence: 8 steps per second. */
export const animationStep = 0.125;
/** Mosaic block size as a fraction of the region's LONG side. */
export const minBlockFraction = 0.015;
export const maxBlockFraction = 0.09;
export const minBlockPoints = 3;

/** Mosaic block size (CIPixellate inputScale) for a strength and region size (RAW size fields). */
export function pixelScale(strength: number, regionSize: Size): number {
  const s = smax(0, smin(1, strength));
  const long = smax(regionSize.width, regionSize.height);
  return smax(minBlockPoints, (minBlockFraction + s * (maxBlockFraction - minBlockFraction)) * long);
}

/** `Int(floor(time / animationStep))` — throws where Swift traps (NaN/∞/overflow). */
export function quantizedStep(time: number): number {
  return sInt(Math.floor(time / animationStep));
}

/** Grid-phase jitter: zero unless animated (and blockSize > 0). */
export function gridJitter(time: number, animated: boolean, blockSize: number): Point {
  if (!(animated && blockSize > 0)) return { x: 0, y: 0 };
  const step = quantizedStep(time);
  return {
    x: (hash01(step, 0x51) - 0.5) * blockSize,
    y: (hash01(step, 0xa7) - 0.5) * blockSize,
  };
}

const MASK64 = (1n << 64n) - 1n;

/**
 * Deterministic 0…1 hash of (step, salt) — splitmix-style UInt64 wrapping
 * arithmetic (`&*`, `&+`), exactly as Swift. `step` / `salt` are Swift `Int`
 * (Int64); pass a bigint for values beyond ±2^53.
 */
export function hash01(step: number | bigint, salt: number | bigint): number {
  const s = BigInt.asUintN(64, BigInt(step));
  const t = BigInt.asUintN(64, BigInt(salt));
  let x = (s * 0x9e3779b97f4a7c15n) & MASK64;
  x = (x + ((t * 0xbf58476d1ce4e5b9n) & MASK64)) & MASK64;
  x ^= x >> 30n;
  x = (x * 0xbf58476d1ce4e5b9n) & MASK64;
  x ^= x >> 27n;
  x = (x * 0x94d049bb133111ebn) & MASK64;
  x ^= x >> 31n;
  return Number(x % 1_000_000_000n) / 1_000_000_000;
}
