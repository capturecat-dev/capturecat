import { describe, expect, it } from "vitest";

import { keyVariation, strokeSamples, tickSamples } from "../../core/audio/sounds";
import { bucketedKeyPitch, KEY_TEST_BURST, SoundPreviewPlayer } from "./soundPreview";

function harness() {
  let t = 100;
  const played: Array<{ samples: Float32Array; volume: number; delay: number }> = [];
  const player = new SoundPreviewPlayer(
    (samples, volume, delay) => played.push({ samples, volume, delay }),
    () => t,
  );
  return { player, played, advance: (dt: number) => (t += dt) };
}

describe("Cursor pane sound previews (ClickSoundPlayer / KeySoundPlayer)", () => {
  it("Test / style pick: one tick of the synthesized style at the volume, unthrottled", () => {
    const { player, played } = harness();
    player.click("Clicky", 0.7);
    player.click("Clicky", 0.7);
    expect(played).toHaveLength(2);
    expect(played[0].samples).toBe(tickSamples("Clicky"));
    expect(played[0].volume).toBe(0.7);
  });

  it("toggle / volume drag: playPreview, at most one tick per 0.15 s", () => {
    const { player, played, advance } = harness();
    player.clickPreview("Pop", 0.5);
    advance(0.1);
    player.clickPreview("Pop", 0.6);
    advance(0.06);
    player.clickPreview("Pop", 0.8);
    expect(played.map((p) => p.volume)).toEqual([0.5, 0.8]);
  });

  it("key Test: the 'the quick' burst, seeded from 1000 + offset, ≥ 0.4 s apart", () => {
    const { player, played, advance } = harness();
    player.keyBurst("Thock", 0.8);
    expect(played.map((p) => p.delay)).toEqual(KEY_TEST_BURST.map(([o]) => o));
    for (let i = 0; i < KEY_TEST_BURST.length; i++) {
      const [offset, category] = KEY_TEST_BURST[i];
      const v = keyVariation(1000 + offset, category);
      expect(played[i].volume).toBeCloseTo(Math.min(1, 0.8 * v.level), 12);
      expect(Array.from(played[i].samples)).toEqual(Array.from(strokeSamples("Thock", bucketedKeyPitch(v.pitch))));
    }
    advance(0.2);
    player.keyBurst("Thock", 0.8);
    expect(played).toHaveLength(KEY_TEST_BURST.length);
    advance(0.25);
    player.keyBurst("Cream", 0.8);
    expect(played).toHaveLength(2 * KEY_TEST_BURST.length);
  });

  it("buckets live key pitch like KeySoundPlayer.play (0.03 steps from 0.75)", () => {
    expect(bucketedKeyPitch(0.94)).toBeCloseTo(0.93, 12);
    expect(bucketedKeyPitch(1.06)).toBeCloseTo(1.05, 12);
    expect(bucketedKeyPitch(0.75)).toBe(0.75);
  });
});
