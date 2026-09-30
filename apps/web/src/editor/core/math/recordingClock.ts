/**
 * Port of Services/RecordingClock.swift — the ONE clock every recording-time
 * tracker reads (CLAUDE.md names it a shared source of truth): origin/pause
 * bookkeeping, host-time → timeline mapping, and the CGEvent timestamp
 * decoding (mach units vs nanoseconds, whichever is plausible).
 *
 * The pure parts only. Swift's `now()` (CMClockGetHostTimeClock seconds) and
 * the `nil → now()` defaults are the caller's job here: every method takes
 * the host time explicitly. The mach timebase (`mach_timebase_info`, 125/3 on
 * Apple silicon, 1/1 on Intel) is a parameter. CGEventTimestamp (UInt64)
 * travels as a `bigint`.
 *
 * Locked by the golden-vector units `recordingClockSequences` (a REAL
 * RecordingClock driven through restart/pause/resume/timelineTime sequences)
 * and `recordingClockEventTimestamp`.
 *
 * Note: the web editor never records, so nothing on the web calls this yet;
 * it exists so recorded timelines (cursor.json / keys.json timestamps) can be
 * reasoned about with the Mac's exact semantics.
 */
import { smax, smin, srounded } from "./swift";

/** Sanity window for a hardware event timestamp (seconds). */
export const maxPlausibleDeliveryLatency = 30.0;
export const maxPlausibleClockSkew = 0.05;

export interface MachTimebase {
  numer: number;
  denom: number;
}

const INT64_MAX = 9223372036854775807n;
const INT64_MIN = -9223372036854775808n;

export class RecordingClock {
  private origin: number;
  private pauseStartHostTime: number | null = null;
  private accumulatedPause = 0;

  /** `init(originHostTimeSeconds:)` with an explicit origin. */
  constructor(originHostTimeSeconds: number) {
    this.origin = originHostTimeSeconds;
  }

  get originHostTimeSeconds(): number {
    return this.origin;
  }

  get isPaused(): boolean {
    return this.pauseStartHostTime !== null;
  }

  get accumulatedPauseSeconds(): number {
    return this.accumulatedPause;
  }

  /** `restart(originHostTimeSeconds:)` */
  restart(originHostTimeSeconds: number): void {
    this.origin = originHostTimeSeconds;
    this.pauseStartHostTime = null;
    this.accumulatedPause = 0;
  }

  /** `pause(at:)` — idempotent; the first call wins. */
  pause(hostTime: number): void {
    if (this.pauseStartHostTime !== null) return;
    this.pauseStartHostTime = hostTime;
  }

  /** `resume(at:)` — idempotent counterpart. */
  resume(hostTime: number): void {
    const start = this.pauseStartHostTime;
    if (start === null) return;
    this.accumulatedPause += smax(0, hostTime - start);
    this.pauseStartHostTime = null;
  }

  /** `timelineTime(forHostTime:)` — paused wall time removed; frozen while paused; ≥ 0. */
  timelineTime(hostTime: number): number {
    const effective = this.pauseStartHostTime !== null ? smin(hostTime, this.pauseStartHostTime) : hostTime;
    return smax(0, effective - this.origin - this.accumulatedPause);
  }

  /** `timelineTime(forEventTimestamp:)` with an explicit `now`. */
  timelineTimeForEventTimestamp(raw: bigint, now: number, timebase: MachTimebase): number {
    return this.timelineTime(hostTimeSeconds(raw, now, timebase));
  }
}

/**
 * `CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(raw))`: a CMTime of
 * timescale 1e9 whose value is trunc(Int64(bitPattern: raw) · numer / denom)
 * (the UInt64 is REINTERPRETED as signed, exact wide arithmetic, truncation
 * toward zero), saturating at the Int64 range; seconds = Double(value) / 1e9.
 */
export function machUnitsSeconds(raw: bigint, timebase: MachTimebase): number {
  const t = machUnitsCMTime(raw, timebase);
  return Number(t.value) / t.timescale;
}

/** `CMClockMakeHostTimeFromSystemUnits(raw)` as (value, timescale). */
export function machUnitsCMTime(raw: bigint, timebase: MachTimebase): { value: bigint; timescale: number } {
  let v = (BigInt.asIntN(64, raw) * BigInt(timebase.numer)) / BigInt(timebase.denom);
  if (v > INT64_MAX) v = INT64_MAX;
  if (v < INT64_MIN) v = INT64_MIN;
  return { value: v, timescale: 1000000000 };
}

/** `hostTimeSeconds(forEventTimestamp:now:)` */
export function hostTimeSeconds(raw: bigint, now: number, timebase: MachTimebase): number {
  if (raw === 0n) return now;
  const plausible = (candidate: number) =>
    candidate <= now + maxPlausibleClockSkew && candidate >= now - maxPlausibleDeliveryLatency;
  const machUnits = machUnitsSeconds(raw, timebase);
  if (plausible(machUnits)) return machUnits;
  const nanoseconds = Number(raw) / 1000000000;
  if (plausible(nanoseconds)) return nanoseconds;
  return now;
}

/** `eventTimestamp(forHostTimeSeconds:)` — inverse of the mach-units reading. */
export function eventTimestamp(hostTime: number, timebase: MachTimebase): bigint {
  const nanos = hostTime * 1000000000;
  const units = (nanos * timebase.denom) / timebase.numer;
  return BigInt(smax(0, srounded(units)));
}
