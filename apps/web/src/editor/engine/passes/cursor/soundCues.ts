/**
 * Click / key sound cue times — exactly the ones the Mac EXPORT mixes
 * (VideoExporter.export ≈ lines 141–152 → ProjectAudioMix.prepare ≈ 162–240).
 * Pure: no DOM, no WebAudio; the audio layer schedules its own sounds.
 *
 * Clicks (`clickSoundEnabled`): `ClickRippleOverlay.discreteClickTimes` over
 * the chain-processed cursor events (smoothing? → spring → end behaviour —
 * the SAME list the ripples use, before the menu-bar shift) with the RECORDED
 * coordinate size (0×0 when cursor.json has none), so a sound fires once per
 * ripple. Then, sorted: kept only inside [effectiveTrimStart, effectiveTrimEnd]
 * and a visible clip (`videoClipSegments` empty → the whole trim range;
 * legacy split points do NOT gate sounds), mapped SOURCE → OUTPUT through
 * the speed map, and throttled to one tick per 50 ms of OUTPUT time.
 *
 * Keys (`keySoundEnabled`): every keys.json event except `scroll`, same
 * range/visibility gate, mapped to OUTPUT. `keyEvents` keeps each event's
 * source timestamp (the Mac seeds each key's synthesis variation from it)
 * and category (key / space / return / delete / modifier).
 */
import type { KeystrokeCategory } from "../../../core/model/enums";
import type { Project } from "../../../core/model/types";
import { discreteClickTimes } from "../../../core/math/clickRippleOverlay";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments } from "../../../core/time/clips";
import { SpeedTimeMap } from "../../../core/time/speedTimeMap";
import { chainedCursorEvents, keystrokeEvents } from "./cursorScene";

export interface KeySoundCue {
  /** OUTPUT seconds. */
  time: number;
  /** SOURCE timestamp — the Mac's per-key synthesis seed (`seedTimestamp`). */
  seed: number;
  category: KeystrokeCategory;
}

export interface SoundCues {
  /** Click tick OUTPUT times (s), ascending, ≥ 50 ms apart. Empty unless `clickSoundEnabled`. */
  clicks: number[];
  /** Key sound OUTPUT times (s), in keys.json order. Empty unless `keySoundEnabled`. */
  keys: number[];
  /** `keys` with their seed + category. */
  keyEvents: KeySoundCue[];
}

/**
 * @param cursorJson parsed cursor.json (`Scene.extras.assets.cursor`), or null
 * @param keysJson   parsed keys.json (`Scene.extras.assets.keystrokes`), or null
 */
export function soundCues(project: Project, cursorJson: unknown, keysJson: unknown): SoundCues {
  const s = project.settings;
  const mapStart = effectiveTrimStart(project);
  const mapEnd = effectiveTrimEnd(project);
  const timeMap = new SpeedTimeMap(mapStart, mapEnd, project.speedRegions);
  const visible =
    project.videoClipSegments.length === 0
      ? [{ startTime: mapStart, endTime: mapEnd }]
      : effectiveVideoClipSegments(project);
  const inRange = (t: number) =>
    t >= mapStart && t <= mapEnd && visible.some((c) => t >= c.startTime && t <= c.endTime);

  const clicks: number[] = [];
  if (s.clickSoundEnabled && project.cursorDataURL) {
    const { events, recordedSize } = chainedCursorEvents(project, cursorJson);
    const times = discreteClickTimes(events, recordedSize).sort((a, b) => a - b);
    let lastOutput = -1.0;
    for (const t of times) {
      if (!inRange(t)) continue;
      const out = timeMap.outputTime(t);
      if (!(out - lastOutput >= 0.05)) continue;
      lastOutput = out;
      clicks.push(out);
    }
  }

  const keyEvents: KeySoundCue[] = [];
  if (s.keySoundEnabled && project.keystrokeDataURL) {
    for (const e of keystrokeEvents(keysJson)) {
      if (e.category === "scroll" || !inRange(e.timestamp)) continue;
      keyEvents.push({ time: timeMap.outputTime(e.timestamp), seed: e.timestamp, category: e.category });
    }
  }
  return { clicks, keys: keyEvents.map((k) => k.time), keyEvents };
}
