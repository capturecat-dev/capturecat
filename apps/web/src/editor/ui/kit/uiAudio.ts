/**
 * UI feedback sounds on the main thread — the web stand-ins for the Mac's
 * `NSSound.beep()` and for the live `AVAudioPlayerNode`s the inspector's
 * sound previews schedule into (ClickSoundPlayer / KeySoundPlayer).
 *
 * One lazily created 48 kHz AudioContext (the rate the synthesized samples
 * are made at). It is created / resumed inside the user gesture that asks
 * for a sound; with no audio device (or no WebAudio) everything stays
 * silent rather than throwing — like the Mac players' `startIfNeeded`.
 */

const RATE = 48_000;
let ctx: AudioContext | null = null;
let unavailable = false;

function context(): AudioContext | null {
  if (unavailable) return null;
  if (!ctx) {
    try {
      ctx = new AudioContext({ latencyHint: "interactive", sampleRate: RATE });
    } catch {
      unavailable = true;
      return null;
    }
  }
  if (ctx.state === "suspended") void ctx.resume().catch(() => {});
  return ctx;
}

/**
 * Schedules mono `samples` (48 kHz) at `volume` (0…1), `delay` seconds from
 * now. Overlapping schedules layer, like `scheduleBuffer(at: nil)`.
 */
export function playSamples(samples: Float32Array, volume: number, delay = 0): void {
  const ac = context();
  if (!ac || samples.length === 0) return;
  const buffer = ac.createBuffer(1, samples.length, RATE);
  buffer.copyToChannel(samples as Float32Array<ArrayBuffer>, 0);
  const source = ac.createBufferSource();
  source.buffer = buffer;
  const gain = ac.createGain();
  gain.gain.value = Math.max(0, Math.min(1, volume));
  source.connect(gain).connect(ac.destination);
  source.start(ac.currentTime + Math.max(0, delay));
}

let beepSamples: Float32Array | null = null;

/**
 * The refusal cue (`NSSound.beep()`): a short, soft two-partial "boop" —
 * the web has no system alert sound to borrow.
 */
export function systemBeep(): void {
  if (!beepSamples) {
    const n = Math.round(RATE * 0.16);
    beepSamples = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const t = i / RATE;
      const attack = Math.min(1, t / 0.004);
      const env = attack * Math.exp(-t * 26);
      beepSamples[i] = env * (0.55 * Math.sin(2 * Math.PI * 660 * t) + 0.2 * Math.sin(2 * Math.PI * 990 * t));
    }
  }
  playSamples(beepSamples, 0.5);
}
