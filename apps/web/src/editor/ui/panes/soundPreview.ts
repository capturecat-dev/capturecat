/**
 * The Cursor pane's sound previews — the live halves of
 * `Services/ClickSoundPlayer.swift` and `Services/KeySoundPlayer.swift`
 * that `CursorSettingsPaneAppKit` calls (Test buttons, style picks, the
 * click toggle / volume drag), over the SAME synthesis the preview and the
 * exporter mix (core/audio/sounds.ts).
 *
 *   ClickSoundPlayer.play(volume:style:)          one tick, unthrottled
 *   ClickSoundPlayer.playPreview(volume:style:)   one tick, ≥ 0.15 s apart
 *   KeySoundPlayer.playTestBurst(volume:style:)   "the quick" burst, ≥ 0.4 s apart
 *
 * Key strokes are played like `KeySoundPlayer.play(timestamp:…)`: variation
 * from the timestamp, pitch bucketed to 0.03 steps from 0.75, level riding
 * the volume.
 */
import type { ClickSoundStyle, KeySoundStyle, KeystrokeCategory } from "../../core/model/enums";
import { keyVariation, strokeSamples, tickSamples } from "../../core/audio/sounds";
import { playSamples } from "../kit/uiAudio";

const CLICK_PREVIEW_INTERVAL = 0.15;
const KEY_BURST_INTERVAL = 0.4;

/** `playTestBurst`'s pattern: (offset s, category). */
export const KEY_TEST_BURST: ReadonlyArray<readonly [number, KeystrokeCategory]> = [
  [0.0, "key"],
  [0.09, "key"],
  [0.17, "key"],
  [0.32, "space"],
  [0.41, "key"],
  [0.5, "key"],
  [0.58, "key"],
  [0.66, "key"],
  [0.74, "key"],
];

/** `KeySoundPlayer.play`'s live-buffer pitch bucket for a variation pitch. */
export function bucketedKeyPitch(pitch: number): number {
  const bucket = Math.trunc((pitch - 0.75) / 0.03);
  return 0.75 + bucket * 0.03;
}

const now = () => (typeof performance !== "undefined" ? performance.now() / 1000 : Date.now() / 1000);

export class SoundPreviewPlayer {
  private lastClickPreview = -Infinity;
  private lastKeyBurst = -Infinity;
  private keyBuffers = new Map<string, Float32Array>();

  constructor(
    private readonly play: (samples: Float32Array, volume: number, delay: number) => void = playSamples,
    private readonly clock: () => number = now,
  ) {}

  /** `ClickSoundPlayer.play(volume:style:)`. */
  click(style: ClickSoundStyle, volume: number): void {
    this.play(tickSamples(style), Math.max(0, Math.min(1, volume)), 0);
  }

  /** `ClickSoundPlayer.playPreview(volume:style:)` — throttled for toggles / slider drags. */
  clickPreview(style: ClickSoundStyle, volume: number): void {
    const t = this.clock();
    if (t - this.lastClickPreview < CLICK_PREVIEW_INTERVAL) return;
    this.lastClickPreview = t;
    this.click(style, volume);
  }

  /** `KeySoundPlayer.playTestBurst(volume:style:)`. */
  keyBurst(style: KeySoundStyle, volume: number): void {
    const t = this.clock();
    if (t - this.lastKeyBurst < KEY_BURST_INTERVAL) return;
    this.lastKeyBurst = t;
    for (const [offset, category] of KEY_TEST_BURST) {
      // Seeded with the offset so each key varies but the burst always sounds the same.
      const v = keyVariation(1000 + offset, category);
      const pitch = bucketedKeyPitch(v.pitch);
      const key = `${style}-${pitch.toFixed(4)}`;
      let samples = this.keyBuffers.get(key);
      if (!samples) {
        samples = strokeSamples(style, pitch);
        this.keyBuffers.set(key, samples);
      }
      this.play(samples, Math.max(0, Math.min(1, volume * v.level)), offset);
    }
  }
}

/** The editor's one preview player (the Mac's `.shared` instances). */
export const soundPreview = new SoundPreviewPlayer();
