/**
 * Opens everything a project's audio mix reads — the recording's audio
 * tracks (file order), each voice-over file, the cursor/keys sidecars — and
 * turns the project into a renderable `AudioMixRenderer`. Used by BOTH the
 * main-thread playback (engine/audio.ts) and the worker exporter
 * (export/audioExport.ts): one plan builder, one renderer.
 *
 * Media stays open across project edits; `update(doc)` re-plans (volumes,
 * trims, speed regions, clips, voice-over placement, click/key settings) and
 * opens any newly referenced voice-over file.
 */
import { ALL_FORMATS, Input, UrlSource } from "mediabunny";
import { exportSoundCues } from "../../core/audio/cues";
import { buildAudioMixPlan, type AudioMixPlan } from "../../core/audio/mixPlan";
import { parseProject, type Project } from "../../core/model";
import { AudioMixRenderer } from "./mixer";
import { PcmTrackReader } from "./pcm";

export interface ProjectAudioInit {
  /** The recording: an already-open mediabunny Input (worker) or its URL. */
  recording: Input | string;
  /** project.json reference → fetchable URL (RenderMedia.files). */
  files: Record<string, string>;
  /** Parsed sidecars when the caller already has them (the worker's SceneAssets). */
  cursorJson?: unknown;
  keysJson?: unknown;
}

async function fetchJson(url: string | undefined): Promise<unknown> {
  if (!url) return null;
  try {
    const res = await fetch(url);
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

const SMPB = [0x69, 0x54, 0x75, 0x6e, 0x53, 0x4d, 0x50, 0x42]; // "iTunSMPB"

function parseSmpb(bytes: Uint8Array): { priming: number; validFrames: number } | null {
  outer: for (let i = 0; i + SMPB.length < bytes.length; i++) {
    for (let k = 0; k < SMPB.length; k++) if (bytes[i + k] !== SMPB[k]) continue outer;
    // name atom, then `data` atom: size, 'data', type, locale, ASCII payload.
    const text = new TextDecoder("latin1").decode(bytes.subarray(i + SMPB.length, Math.min(bytes.length, i + 260)));
    const at = text.indexOf("data");
    if (at < 0) return null;
    const fields = text
      .slice(at + 12)
      .trim()
      .split(/\s+/)
      .filter((f) => /^[0-9A-Fa-f]+$/.test(f));
    if (fields.length < 4) return null;
    return { priming: parseInt(fields[1], 16), validFrames: parseInt(fields[3], 16) };
  }
  return null;
}

/**
 * iTunSMPB gapless info of an MPEG-4 audio file (head, then tail when the
 * `moov` sits at the end) — what AVFoundation uses to hide AAC priming in
 * files without an edit list.
 */
async function readGapless(url: string): Promise<{ priming: number; validFrames: number } | null> {
  try {
    const head = await fetch(url, { headers: { Range: "bytes=0-262143" } });
    if (!head.ok) return null;
    const bytes = new Uint8Array(await head.arrayBuffer());
    const found = parseSmpb(bytes);
    if (found) return found;
    const size = Number(head.headers.get("content-range")?.split("/")[1] ?? 0);
    if (!(size > bytes.length)) return null;
    const tail = await fetch(url, { headers: { Range: `bytes=${Math.max(0, size - 262144)}-${size - 1}` } });
    return tail.ok ? parseSmpb(new Uint8Array(await tail.arrayBuffer())) : null;
  } catch {
    return null;
  }
}

export class ProjectAudio {
  private input: Input | null = null;
  private ownsInput = false;
  private recordingReaders: (PcmTrackReader | null)[] = [];
  private assetDuration = 0;
  private voices = new Map<string, { input: Input; reader: PcmTrackReader | null }>();
  private sidecars = new Map<string, unknown>();
  renderer: AudioMixRenderer | null = null;
  plan: AudioMixPlan | null = null;
  private disposed = false;
  private version = 0;

  private constructor(private files: Record<string, string>) {}

  static async open(init: ProjectAudioInit, doc: unknown): Promise<ProjectAudio> {
    const pa = new ProjectAudio(init.files);
    if (typeof init.recording === "string") {
      pa.input = new Input({ formats: ALL_FORMATS, source: new UrlSource(init.recording) });
      pa.ownsInput = true;
    } else {
      pa.input = init.recording;
    }
    const tracks = await pa.input.getAudioTracks();
    pa.recordingReaders = await Promise.all(tracks.map((t) => PcmTrackReader.open(t).catch(() => null)));
    pa.assetDuration = await pa.input.computeDuration();
    if (init.cursorJson !== undefined) pa.sidecarsFromCaller.cursor = init.cursorJson;
    if (init.keysJson !== undefined) pa.sidecarsFromCaller.keys = init.keysJson;
    await pa.update(doc);
    return pa;
  }

  private sidecarsFromCaller: { cursor?: unknown; keys?: unknown } = {};

  setFiles(files: Record<string, string>): void {
    this.files = files;
  }

  /** Re-plans for an edited project.json. Resolves with the new plan (null = no audio track). */
  async update(doc: unknown): Promise<AudioMixPlan | null> {
    // Rapid edits (a volume drag) can overlap: only the newest one lands.
    const version = ++this.version;
    let project: Project;
    try {
      project = parseProject(doc);
    } catch {
      this.plan = null;
      this.renderer = null;
      return null;
    }
    const cursorJson = await this.sidecar("cursor", project.cursorDataURL, project.settings.clickSoundEnabled);
    const keysJson = await this.sidecar("keys", project.keystrokeDataURL ?? null, project.settings.keySoundEnabled);
    const cues = exportSoundCues(project, cursorJson, keysJson);

    // Voice-overs: "file exists" == referenced, fetchable and decodable.
    const voiceDurations: Record<string, number> = {};
    for (const clip of project.voiceOverClips) {
      const v = await this.voice(clip.fileName);
      if (v?.reader) voiceDurations[clip.fileName] = v.reader.duration;
    }
    if (this.disposed) return null;
    if (version !== this.version) return this.plan;
    const plan = buildAudioMixPlan(project, cues, {
      assetDuration: this.assetDuration,
      recordingTracks: this.recordingReaders.map((r) => ({ duration: r?.duration ?? 0 })),
      voiceDurations,
    });
    const voices = new Map<string, PcmTrackReader>();
    for (const [name, v] of this.voices) if (v.reader) voices.set(name, v.reader);
    this.plan = plan;
    this.renderer = plan ? new AudioMixRenderer(plan, { recording: this.recordingReaders, voices }) : null;
    return plan;
  }

  private async sidecar(kind: "cursor" | "keys", ref: string | null, needed: boolean): Promise<unknown> {
    if (!needed || !ref) return null;
    const given = this.sidecarsFromCaller[kind];
    if (given !== undefined && given !== null) return given;
    const key = `${kind}:${ref}`;
    if (!this.sidecars.has(key)) this.sidecars.set(key, await fetchJson(this.files[ref]));
    return this.sidecars.get(key);
  }

  private async voice(fileName: string) {
    const existing = this.voices.get(fileName);
    if (existing) return existing;
    const url = this.files[fileName];
    if (!url) return null;
    const input = new Input({ formats: ALL_FORMATS, source: new UrlSource(url) });
    let reader: PcmTrackReader | null = null;
    try {
      const track = await input.getPrimaryAudioTrack();
      reader = track ? await PcmTrackReader.open(track, await readGapless(url)) : null;
    } catch {
      reader = null;
    }
    const entry = { input, reader };
    this.voices.set(fileName, entry);
    return entry;
  }

  /** True when the recording has at least one decodable audio track. */
  get hasRecordedAudio(): boolean {
    return this.recordingReaders.some((r) => r !== null);
  }

  dispose(): void {
    this.disposed = true;
    for (const r of this.recordingReaders) r?.dispose();
    for (const v of this.voices.values()) {
      v.reader?.dispose();
      v.input.dispose();
    }
    this.voices.clear();
    if (this.ownsInput) this.input?.dispose();
    this.input = null;
  }
}
