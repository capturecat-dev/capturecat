/**
 * The camera person-mask track: `camera-mask.ccmask` in the project folder.
 *
 * The cutout and pop-out camera layouts draw the webcam through this alpha
 * mask. It is the SHARED SOURCE OF TRUTH between the Mac app and the web
 * editor: whichever side segmented the camera (Vision on the Mac, MODNet in
 * the browser) writes this file, and both renderers read the identical
 * decoded bytes. The format is lossless, so decoded masks are bit-identical
 * no matter which encoder produced the compressed bytes.
 *
 * Twin: apps/macos/CaptureCat/Services/CameraMaskTrack.swift — keep the two
 * byte-for-byte compatible (the --web-vectors harness writes a fixture the
 * vitest suite decodes).
 *
 * Layout (all integers little-endian):
 *
 *   offset size  field
 *   0      4     magic "CCMK"
 *   4      2     version (1)
 *   6      2     width   (mask pixels)
 *   8      2     height
 *   10     2     keyframeInterval (a full frame at least this often)
 *   12     4     frameCount
 *   16     8     sourceDuration (f64 seconds of the camera video it was made from)
 *   24     8     sourceByteSize (f64; the camera file's size, a staleness check)
 *   32     16×N  index: per frame { time f64 (camera-source seconds), offset u32,
 *                lengthAndKind u32 } — the low 31 bits are the payload length,
 *                the high bit set means the payload is a DELTA.
 *   …            payloads: raw DEFLATE (RFC 1951) of width×height bytes. A key
 *                frame holds alpha (0 = background, 255 = person); a delta holds
 *                alpha XOR the previous frame's alpha. The encoder stores
 *                whichever is smaller, but frame 0 is always a key and no frame
 *                is more than keyframeInterval − 1 deltas from its key, so a
 *                seek inflates at most keyframeInterval payloads.
 *
 * Frame times are strictly increasing. The mask for camera time t is the
 * last frame whose time ≤ t (the first frame before it) — see frameIndexAt.
 */

export const CCMASK_MAGIC = "CCMK";
export const CCMASK_VERSION = 1;
export const CCMASK_HEADER_BYTES = 32;
export const CCMASK_INDEX_ENTRY_BYTES = 16;
/** The file name inside a project folder. */
export const CAMERA_MASK_FILE = "camera-mask.ccmask";

export interface CameraMaskHeader {
  width: number;
  height: number;
  keyframeInterval: number;
  frameCount: number;
  sourceDuration: number;
  sourceByteSize: number;
}

export interface CameraMaskIndexEntry {
  time: number;
  offset: number;
  length: number;
  /** XOR against the previous frame rather than a full alpha frame. */
  delta: boolean;
}

const DELTA_BIT = 0x8000_0000;

export interface CameraMaskTrack {
  header: CameraMaskHeader;
  index: CameraMaskIndexEntry[];
  bytes: Uint8Array;
}

/** Raw DEFLATE through the platform streams (browser and Node 18+). */
async function pump(stream: CompressionStream | DecompressionStream, input: Uint8Array): Promise<Uint8Array> {
  const out = new Response(new Blob([input as BlobPart]).stream().pipeThrough(stream));
  return new Uint8Array(await out.arrayBuffer());
}
export const inflateRaw = (input: Uint8Array) => pump(new DecompressionStream("deflate-raw"), input);
export const deflateRaw = (input: Uint8Array) => pump(new CompressionStream("deflate-raw"), input);

export function parseCameraMask(bytes: Uint8Array): CameraMaskTrack {
  if (bytes.length < CCMASK_HEADER_BYTES) throw new Error("camera mask: truncated header");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const magic = String.fromCharCode(bytes[0]!, bytes[1]!, bytes[2]!, bytes[3]!);
  if (magic !== CCMASK_MAGIC) throw new Error("camera mask: bad magic");
  const version = view.getUint16(4, true);
  if (version !== CCMASK_VERSION) throw new Error(`camera mask: unsupported version ${version}`);
  const header: CameraMaskHeader = {
    width: view.getUint16(6, true),
    height: view.getUint16(8, true),
    keyframeInterval: view.getUint16(10, true),
    frameCount: view.getUint32(12, true),
    sourceDuration: view.getFloat64(16, true),
    sourceByteSize: view.getFloat64(24, true),
  };
  if (header.width === 0 || header.height === 0 || header.keyframeInterval === 0) {
    throw new Error("camera mask: zero dimension or keyframe interval");
  }
  const indexEnd = CCMASK_HEADER_BYTES + header.frameCount * CCMASK_INDEX_ENTRY_BYTES;
  if (bytes.length < indexEnd) throw new Error("camera mask: truncated index");
  const index: CameraMaskIndexEntry[] = [];
  let lastTime = -Infinity;
  for (let i = 0; i < header.frameCount; i++) {
    const at = CCMASK_HEADER_BYTES + i * CCMASK_INDEX_ENTRY_BYTES;
    const lengthAndKind = view.getUint32(at + 12, true);
    const entry = {
      time: view.getFloat64(at, true),
      offset: view.getUint32(at + 8, true),
      length: (lengthAndKind & ~DELTA_BIT) >>> 0,
      delta: (lengthAndKind & DELTA_BIT) !== 0,
    };
    if (!(entry.time > lastTime)) throw new Error("camera mask: frame times must increase");
    if (i === 0 && entry.delta) throw new Error("camera mask: the first frame must be a key frame");
    if (entry.offset < indexEnd || entry.offset + entry.length > bytes.length) throw new Error("camera mask: payload out of range");
    lastTime = entry.time;
    index.push(entry);
  }
  return { header, index, bytes };
}

/** The frame showing at camera-source time t: the last frame with time ≤ t,
 *  clamped to the first frame before it. -1 for an empty track. */
export function frameIndexAt(index: readonly CameraMaskIndexEntry[], t: number): number {
  if (index.length === 0) return -1;
  let lo = 0;
  let hi = index.length - 1;
  if (t < index[0]!.time) return 0;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (index[mid]!.time <= t) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/**
 * Decodes frames with a one-frame cursor, so sequential playback inflates one
 * payload per frame and a seek replays at most keyframeInterval frames.
 */
export class CameraMaskDecoder {
  private current = -1;
  private alpha: Uint8Array;

  constructor(readonly track: CameraMaskTrack) {
    this.alpha = new Uint8Array(track.header.width * track.header.height);
  }

  private async payload(i: number): Promise<Uint8Array> {
    const { offset, length } = this.track.index[i]!;
    const raw = await inflateRaw(this.track.bytes.subarray(offset, offset + length));
    if (raw.length !== this.alpha.length) throw new Error(`camera mask: frame ${i} inflates to ${raw.length} bytes`);
    return raw;
  }

  /** The key frame frame i is built from (itself when it is a key). */
  private keyFor(i: number): number {
    let k = i;
    while (k > 0 && this.track.index[k]!.delta) k--;
    return k;
  }

  /** The alpha of frame i (width×height bytes). The returned array is reused:
   *  copy it if it must outlive the next call. */
  async frame(i: number): Promise<Uint8Array> {
    if (i < 0 || i >= this.track.header.frameCount) throw new Error(`camera mask: no frame ${i}`);
    if (i === this.current) return this.alpha;
    const key = this.keyFor(i);
    // Moving forward inside the same key's run: apply only the new deltas.
    let next = this.current >= key && this.current < i ? this.current + 1 : key;
    for (let f = next; f <= i; f++) {
      const body = await this.payload(f);
      if (!this.track.index[f]!.delta) this.alpha.set(body);
      else for (let p = 0; p < body.length; p++) this.alpha[p]! ^= body[p]!;
    }
    this.current = i;
    return this.alpha;
  }

  /** The alpha showing at camera-source time t. */
  async at(t: number): Promise<{ index: number; alpha: Uint8Array }> {
    const index = frameIndexAt(this.track.index, t);
    return { index, alpha: await this.frame(index) };
  }
}

/**
 * Builds a track one alpha frame at a time (the web segmentation path keeps
 * only the compressed payloads and the previous frame — a long camera never
 * holds every decoded mask at once). Same bytes as `encodeCameraMask`.
 */
export class CameraMaskEncoder {
  private readonly size: number;
  private readonly payloads: Uint8Array[] = [];
  private readonly deltas: boolean[] = [];
  private readonly times: number[] = [];
  private previous: Uint8Array | null = null;
  private sinceKey = 0;

  constructor(readonly header: Omit<CameraMaskHeader, "frameCount">) {
    this.size = header.width * header.height;
  }

  get frameCount(): number {
    return this.times.length;
  }

  /** Appends a frame (times strictly increasing). `alpha` is copied when kept. */
  async add(time: number, alpha: Uint8Array): Promise<void> {
    const i = this.times.length;
    const size = this.size;
    if (alpha.length !== size) throw new Error(`camera mask: frame ${i} has ${alpha.length} bytes, expected ${size}`);
    if (i > 0 && !(time > this.times[i - 1]!)) throw new Error("camera mask: frame times must increase");
    const key = await deflateRaw(alpha);
    let chosen = key;
    let isDelta = false;
    const previous = this.previous;
    if (previous && this.sinceKey + 1 < this.header.keyframeInterval) {
      const xor = new Uint8Array(size);
      for (let p = 0; p < size; p++) xor[p] = alpha[p]! ^ previous[p]!;
      const delta = await deflateRaw(xor);
      if (delta.length < key.length) {
        chosen = delta;
        isDelta = true;
      }
    }
    this.sinceKey = isDelta ? this.sinceKey + 1 : 0;
    this.payloads.push(chosen);
    this.deltas.push(isDelta);
    this.times.push(time);
    this.previous = alpha.slice();
  }

  /** The finished file. */
  finish(): Uint8Array {
    const { header, payloads, deltas, times } = this;
    const indexEnd = CCMASK_HEADER_BYTES + times.length * CCMASK_INDEX_ENTRY_BYTES;
    const total = indexEnd + payloads.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(total);
    const view = new DataView(out.buffer);
    out.set([...CCMASK_MAGIC].map((c) => c.charCodeAt(0)), 0);
    view.setUint16(4, CCMASK_VERSION, true);
    view.setUint16(6, header.width, true);
    view.setUint16(8, header.height, true);
    view.setUint16(10, header.keyframeInterval, true);
    view.setUint32(12, times.length, true);
    view.setFloat64(16, header.sourceDuration, true);
    view.setFloat64(24, header.sourceByteSize, true);
    let offset = indexEnd;
    for (let i = 0; i < times.length; i++) {
      const at = CCMASK_HEADER_BYTES + i * CCMASK_INDEX_ENTRY_BYTES;
      view.setFloat64(at, times[i]!, true);
      view.setUint32(at + 8, offset, true);
      view.setUint32(at + 12, (payloads[i]!.length | (deltas[i] ? DELTA_BIT : 0)) >>> 0, true);
      out.set(payloads[i]!, offset);
      offset += payloads[i]!.length;
    }
    return out;
  }
}

/** Builds a track from full alpha frames (the web segmentation path). */
export async function encodeCameraMask(
  header: Omit<CameraMaskHeader, "frameCount">,
  frames: ReadonlyArray<{ time: number; alpha: Uint8Array }>,
): Promise<Uint8Array> {
  const encoder = new CameraMaskEncoder(header);
  for (const { time, alpha } of frames) await encoder.add(time, alpha);
  return encoder.finish();
}
