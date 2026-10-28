/**
 * The recording's natural size — AVAssetTrack.naturalSize: square-pixel,
 * BEFORE rotation — read from its MP4 / QuickTime boxes, for Auto Zoom on
 * the server (AutoZoomApplier's screen size is that size halved).
 *
 * The web editor gets the same number from mediabunny
 * (apps/web/src/editor/engine/media/demux.ts: getSquarePixelWidth/Height),
 * whose ISOBMFF demuxer reads it as: the video track's `stsd` sample entry
 * width/height, stretched along one axis by the entry's `pasp` box (num > den
 * widens, otherwise heightens; Math.round). This reads exactly that, for the
 * FIRST video track (`hdlr` = vide) as AutoZoomApplier does — and nothing
 * else: no sample tables, no codec config, no media data.
 *
 * I/O is ranged reads: top-level box headers (16 bytes each) until `moov`,
 * then `moov` itself. A Mac recording's moov is usually at the END of the
 * file (after mdat), so this is typically 3-4 small reads plus the moov.
 */

/** Reads `length` bytes at `offset` (an R2 ranged GET in the Worker). */
export type RangeReader = (offset: number, length: number) => Promise<Uint8Array>;

/** moov larger than this is refused (a multi-hour recording's sample tables
 *  are a few MB; this only bounds a hostile file's memory). */
export const MAX_MOOV_BYTES = 64 * 1024 * 1024;
/** Top-level boxes walked before giving up. */
const MAX_TOP_LEVEL_BOXES = 256;

export interface NaturalSize {
  width: number;
  height: number;
}

interface Box {
  type: string;
  /** Start of the payload (after the header) in the buffer. */
  start: number;
  /** End of the box in the buffer. */
  end: number;
}

function u32(b: Uint8Array, at: number): number {
  return ((b[at] << 24) >>> 0) + (b[at + 1] << 16) + (b[at + 2] << 8) + b[at + 3];
}

function u16(b: Uint8Array, at: number): number {
  return (b[at] << 8) + b[at + 1];
}

function ascii(b: Uint8Array, at: number): string {
  return String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
}

/** The child boxes in `b[from, to)`; stops at the first malformed header. */
function children(b: Uint8Array, from: number, to: number): Box[] {
  const out: Box[] = [];
  let pos = from;
  while (pos + 8 <= to) {
    let size = u32(b, pos);
    const type = ascii(b, pos + 4);
    let header = 8;
    if (size === 1) {
      if (pos + 16 > to) break;
      size = u32(b, pos + 8) * 2 ** 32 + u32(b, pos + 12);
      header = 16;
    } else if (size === 0) {
      size = to - pos;
    }
    if (size < header || pos + size > to) break;
    out.push({ type, start: pos + header, end: pos + size });
    pos += size;
  }
  return out;
}

function child(b: Uint8Array, box: Box, type: string): Box | undefined {
  return children(b, box.start, box.end).find((c) => c.type === type);
}

/** `trak` → its video sample entry's square-pixel size, or null (not video). */
function trackSize(b: Uint8Array, trak: Box): NaturalSize | null {
  const mdia = child(b, trak, "mdia");
  if (!mdia) return null;
  const hdlr = child(b, mdia, "hdlr");
  // FullBox version+flags (4), pre_defined (4), handler_type (4).
  if (!hdlr || hdlr.start + 12 > hdlr.end || ascii(b, hdlr.start + 8) !== "vide") return null;
  const minf = child(b, mdia, "minf");
  const stbl = minf && child(b, minf, "stbl");
  const stsd = stbl && child(b, stbl, "stsd");
  // FullBox version+flags (4), entry_count (4), then the first sample entry.
  if (!stsd || stsd.start + 8 > stsd.end || u32(b, stsd.start + 4) < 1) return null;
  const entry = children(b, stsd.start + 8, stsd.end)[0];
  // VisualSampleEntry: reserved (6) + data_reference_index (2) + pre_defined (2)
  // + reserved (2) + pre_defined (12), then width (2) + height (2), then
  // resolutions (8) + reserved (4) + frame_count (2) + compressorname (32)
  // + depth (2) + pre_defined (2) = 78 bytes before the child boxes.
  if (!entry || entry.start + 78 > entry.end) return null;
  let width = u16(b, entry.start + 24);
  let height = u16(b, entry.start + 26);
  const pasp = children(b, entry.start + 78, entry.end).find((c) => c.type === "pasp");
  if (pasp && pasp.start + 8 <= pasp.end) {
    const num = u32(b, pasp.start);
    const den = u32(b, pasp.start + 4);
    // mediabunny's rule (its issue #362): stretch the axis that grows.
    if (num > 0 && den > 0) {
      if (num > den) width = Math.round((width * num) / den);
      else height = Math.round((height * den) / num);
    }
  }
  return width > 0 && height > 0 ? { width, height } : null;
}

/** The first video track's natural size in a `moov` box's payload, or null. */
export function naturalSizeFromMoov(moov: Uint8Array): NaturalSize | null {
  for (const trak of children(moov, 0, moov.byteLength)) {
    if (trak.type !== "trak") continue;
    const size = trackSize(moov, trak);
    if (size) return size;
  }
  return null;
}

/**
 * The first video track's natural size, or null when the file has no
 * readable moov / video track (AutoZoomApplier then falls back to 3840×2160,
 * exactly as when AVFoundation cannot open the file).
 */
export async function readNaturalSize(read: RangeReader, fileSize: number): Promise<NaturalSize | null> {
  let pos = 0;
  for (let i = 0; i < MAX_TOP_LEVEL_BOXES && pos + 8 <= fileSize; i++) {
    const head = await read(pos, Math.min(16, fileSize - pos));
    if (head.byteLength < 8) return null;
    let size = u32(head, 0);
    const type = ascii(head, 4);
    let header = 8;
    if (size === 1) {
      if (head.byteLength < 16) return null;
      size = u32(head, 8) * 2 ** 32 + u32(head, 12);
      header = 16;
    } else if (size === 0) {
      size = fileSize - pos;
    }
    if (size < header || pos + size > fileSize) return null;
    if (type === "moov") {
      if (size > MAX_MOOV_BYTES) return null;
      const box = await read(pos, size);
      return box.byteLength === size ? naturalSizeFromMoov(box.subarray(header)) : null;
    }
    pos += size;
  }
  return null;
}
