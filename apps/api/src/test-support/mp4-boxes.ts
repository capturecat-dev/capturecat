/**
 * TEST-ONLY: minimal MP4 / QuickTime files built box by box — just enough
 * structure (ftyp, mdat, moov/trak/mdia/hdlr/minf/stbl/stsd + an optional
 * pasp) for lib/mp4-natural-size.ts to find a video track's size. The
 * same reader is cross-checked against mediabunny (the web engine's
 * demuxer) on real muxed files in apps/web (engine/media/naturalSize.test.ts).
 * Never imported by Worker code.
 */

function u32(n: number): number[] {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
}

function u16(n: number): number[] {
  return [(n >>> 8) & 255, n & 255];
}

function fourcc(type: string): number[] {
  return [...type].map((c) => c.charCodeAt(0));
}

export function box(type: string, ...payload: number[][]): number[] {
  const body = payload.flat();
  return [...u32(8 + body.length), ...fourcc(type), ...body];
}

/** A box written with the 64-bit `largesize` header form. */
export function largeBox(type: string, ...payload: number[][]): number[] {
  const body = payload.flat();
  return [...u32(1), ...fourcc(type), ...u32(0), ...u32(16 + body.length), ...body];
}

function hdlr(handler: string): number[] {
  return box("hdlr", [0, 0, 0, 0], u32(0), fourcc(handler), new Array(12).fill(0), [0]);
}

/** A VisualSampleEntry (`avc1`) of `width`×`height`, with an optional pasp. */
function visualEntry(width: number, height: number, pasp?: [number, number]): number[] {
  const fields = [
    ...new Array(6).fill(0), ...u16(1), // reserved, data_reference_index
    ...u16(0), ...u16(0), ...new Array(12).fill(0), // pre_defined, reserved, pre_defined
    ...u16(width), ...u16(height),
    ...u32(0x00480000), ...u32(0x00480000), ...u32(0), ...u16(1), // resolutions, reserved, frame_count
    ...new Array(32).fill(0), ...u16(0x18), ...u16(0xffff), // compressorname, depth, pre_defined
  ];
  const children = [box("avcC", [1, 0x64, 0, 0x28, 0xff, 0xe0, 0]), ...(pasp ? [box("pasp", u32(pasp[0]), u32(pasp[1]))] : [])];
  return box("avc1", fields, ...children);
}

function audioEntry(): number[] {
  return box("mp4a", new Array(6).fill(0), u16(1), new Array(20).fill(0));
}

export interface TrackSpec {
  kind: "video" | "audio";
  width?: number;
  height?: number;
  pasp?: [number, number];
}

function trak(t: TrackSpec): number[] {
  const entry = t.kind === "video" ? visualEntry(t.width ?? 0, t.height ?? 0, t.pasp) : audioEntry();
  const stsd = box("stsd", [0, 0, 0, 0], u32(1), entry);
  return box(
    "trak",
    box("tkhd", new Array(84).fill(0)),
    box("mdia", box("mdhd", new Array(24).fill(0)), hdlr(t.kind === "video" ? "vide" : "soun"), box("minf", box("stbl", stsd))),
  );
}

export interface Mp4Spec {
  tracks: TrackSpec[];
  /** moov after mdat (AVAssetWriter's default) or before it (fast start). */
  moovAtEnd?: boolean;
  /** mdat payload size (the "media"). */
  mdatBytes?: number;
  /** Write the mdat with a 64-bit largesize header. */
  largeMdat?: boolean;
}

export function mp4File(spec: Mp4Spec): Uint8Array {
  const ftyp = box("ftyp", fourcc("qt  "), u32(0), fourcc("qt  "));
  const media = new Array(spec.mdatBytes ?? 64).fill(7);
  const mdat = spec.largeMdat ? largeBox("mdat", media) : box("mdat", media);
  const moov = box("moov", box("mvhd", new Array(100).fill(0)), ...spec.tracks.map(trak));
  const parts = spec.moovAtEnd === false ? [ftyp, moov, mdat] : [ftyp, box("wide", []), mdat, moov];
  return new Uint8Array(parts.flat());
}
