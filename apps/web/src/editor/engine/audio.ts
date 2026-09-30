/**
 * Main-thread audio playback + master-clock source.
 *
 * AudioContext does not exist in workers, so audio lives here and the
 * render worker follows it: while playing, `sample()` reads
 * `getOutputTimestamp()` (what the speakers are playing NOW, latency
 * included) and the client forwards it as a `clock` message.
 *
 * What plays is the EXPORT's audio: the project's `AudioMixPlan`
 * (core/audio/mixPlan.ts — the ProjectAudioMix port: recorded tracks with
 * their volumes, trim, cut clips, pitch-preserved speed regions, voice-overs,
 * click ticks, key sounds) rendered by the same `AudioMixRenderer` the
 * exporter encodes, in short chunks scheduled back-to-back on a 48 kHz
 * context. Preview == export for sound, sample for sample.
 */
import type { AudioMixPlan } from "../core/audio/mixPlan";
import { ProjectAudio, type ProjectAudioInit } from "./audio/projectAudio";

const RATE = 48_000;
const LEAD = 0.06; // s of scheduling lead so the first buffer is never late
const AHEAD = 0.4; // s rendered + scheduled ahead of the output clock
const CHUNK = 4_800; // frames per scheduled buffer (100 ms)

export class AudioPlayback {
  private ctx: AudioContext;
  private gain: GainNode;
  private pa: ProjectAudio | null = null;
  private session = 0;
  private nodes = new Set<AudioBufferSourceNode>();
  private startCtx = 0;
  private startMedia = 0;
  private rate = 1;
  private playing = false;
  private planKey = "";
  /** Diagnostics: buffers scheduled, buffers that missed their start, render cost. */
  readonly stats = { chunks: 0, late: 0, renderMsMax: 0, renderMsTotal: 0 };

  private constructor() {
    this.ctx = new AudioContext({ latencyHint: "interactive", sampleRate: RATE });
    this.gain = this.ctx.createGain();
    this.gain.connect(this.ctx.destination);
  }

  /** Opens the recording's audio tracks, voice-overs and sidecars for `doc`. */
  static async open(init: ProjectAudioInit, doc: unknown): Promise<AudioPlayback> {
    const p = new AudioPlayback();
    p.pa = await ProjectAudio.open(init, doc);
    p.planKey = structuralKey(p.pa.plan);
    return p;
  }

  /** True when the project's export would carry an audio track. */
  get hasAudio(): boolean {
    return !!this.pa?.renderer;
  }

  get plan(): AudioMixPlan | null {
    return this.pa?.plan ?? null;
  }

  /**
   * Re-plans after an edit. A structural change (timing, sources, sounds on/off)
   * restarts the scheduled audio at the current position; a volume-only change
   * lands with the next chunk (≤ AHEAD later), so slider drags never stutter.
   */
  async setProject(doc: unknown): Promise<void> {
    if (!this.pa) return;
    const plan = await this.pa.update(doc);
    const key = structuralKey(plan);
    const structural = key !== this.planKey;
    this.planKey = key;
    if (this.playing && structural) {
      const s = this.sample();
      const now = performance.timeOrigin + performance.now();
      this.start({ time: s ? s.mediaTime + ((now - s.wallMs) / 1000) * this.rate : this.startMedia, wallMs: now, rate: this.rate });
    }
  }

  setFiles(files: Record<string, string>): void {
    this.pa?.setFiles(files);
  }

  /**
   * Starts audio IN PHASE with the video clock: `transport` says the video
   * shows output time `time` at wall `wallMs`, advancing at `rate`. The first
   * buffer is scheduled LEAD seconds out, so it starts at the media time the
   * video will have reached when that sample becomes audible — no initial
   * offset for the master-clock sync to yank the video back by.
   */
  start(transport: { time: number; wallMs: number; rate: number }): void {
    this.stop();
    if (!this.pa?.renderer) return;
    const session = ++this.session;
    this.playing = true;
    this.rate = transport.rate;
    void this.ctx.resume();
    const T = this.ctx.currentTime + LEAD;
    const ts = this.ctx.getOutputTimestamp();
    const running = this.ctx.state === "running" && ts.contextTime !== undefined && ts.performanceTime !== undefined;
    const audibleWall = running
      ? performance.timeOrigin + ts.performanceTime! + (T - ts.contextTime!) * 1000
      : performance.timeOrigin + performance.now() + (LEAD + this.ctx.baseLatency) * 1000;
    const media = transport.time + ((audibleWall - transport.wallMs) / 1000) * transport.rate;
    this.startCtx = T;
    this.startMedia = Math.max(0, media);
    void this.schedule(session);
  }

  private async schedule(session: number): Promise<void> {
    const startFrame = Math.round(this.startMedia * RATE);
    let frame = startFrame;
    try {
      while (session === this.session) {
        const renderer = this.pa?.renderer;
        if (!renderer || frame >= renderer.endFrame) return;
        const n = Math.min(CHUNK, renderer.endFrame - frame);
        const r0 = performance.now();
        const [l, r] = await renderer.render(frame, n);
        const renderMs = performance.now() - r0;
        if (session !== this.session) return;
        this.stats.chunks++;
        this.stats.renderMsTotal += renderMs;
        this.stats.renderMsMax = Math.max(this.stats.renderMsMax, renderMs);
        let when = this.startCtx + (frame - startFrame) / RATE / this.rate;
        let offset = 0;
        if (when < this.ctx.currentTime) {
          offset = (this.ctx.currentTime - when) * this.rate;
          when = this.ctx.currentTime;
          this.stats.late++;
        }
        if (offset < n / RATE) {
          const buffer = this.ctx.createBuffer(2, n, RATE);
          buffer.copyToChannel(l as Float32Array<ArrayBuffer>, 0);
          buffer.copyToChannel(r as Float32Array<ArrayBuffer>, 1);
          const node = this.ctx.createBufferSource();
          node.buffer = buffer;
          node.playbackRate.value = this.rate;
          node.connect(this.gain);
          node.onended = () => this.nodes.delete(node);
          node.start(when, offset);
          this.nodes.add(node);
        }
        frame += n;
        // Stay ~AHEAD seconds in front of the speakers.
        while (session === this.session && when - this.ctx.currentTime > AHEAD) {
          await new Promise((res) => setTimeout(res, 25));
        }
      }
    } catch (e) {
      if (session === this.session) console.warn("[engine] audio render stopped:", e);
    }
  }

  stop(): void {
    this.session++;
    this.playing = false;
    for (const n of this.nodes) {
      try {
        n.stop();
      } catch {
        /* not started */
      }
    }
    this.nodes.clear();
  }

  /** (output time now at the speakers, wall ms) — the master clock sample. */
  sample(): { mediaTime: number; wallMs: number } | null {
    if (!this.playing) return null;
    const ts = this.ctx.getOutputTimestamp();
    if (ts.contextTime === undefined || ts.performanceTime === undefined) return null;
    if (ts.contextTime < this.startCtx) return null;
    return {
      mediaTime: this.startMedia + (ts.contextTime - this.startCtx) * this.rate,
      wallMs: performance.timeOrigin + ts.performanceTime,
    };
  }

  dispose(): void {
    this.stop();
    this.pa?.dispose();
    this.pa = null;
    void this.ctx.close();
  }
}

/** Everything in a plan except the mix volumes (a change here restarts playback). */
function structuralKey(plan: AudioMixPlan | null): string {
  if (!plan) return "none";
  return JSON.stringify({
    ...plan,
    recording: { ...plan.recording, tracks: plan.recording.tracks.map((t) => ({ ...t, volume: t.volume === 0 })) },
    voiceOvers: plan.voiceOvers.map((v) => ({ ...v, volume: v.volume === 0 })),
    clicks: plan.clicks && { ...plan.clicks, volume: plan.clicks.volume === 0 },
    keys: plan.keys && { ...plan.keys, volume: plan.keys.volume === 0 },
  });
}
