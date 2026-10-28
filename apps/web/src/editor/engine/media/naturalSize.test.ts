/**
 * The API's MP4 natural-size reader (apps/api/src/lib/mp4-natural-size.ts —
 * Auto Zoom's screen size for the remote MCP editing tools) must report what
 * this engine's demuxer reports (demux.ts: mediabunny getSquarePixelWidth/
 * Height), or a cloud auto_zoom would zoom differently from the editor's.
 * Real files muxed by mediabunny: MOV with the moov at the end (the Mac's
 * layout) and fast-start MP4, with and without a pixel-aspect (pasp) box.
 */
import { describe, expect, it } from "vitest";
import {
  ALL_FORMATS,
  BufferSource,
  BufferTarget,
  EncodedPacket,
  EncodedVideoPacketSource,
  Input,
  MovOutputFormat,
  Mp4OutputFormat,
  Output,
} from "mediabunny";
import { readNaturalSize } from "../../../../../api/src/lib/mp4-natural-size";

async function mux(opts: {
  format: "mov" | "mp4";
  fastStart: false | "in-memory";
  width: number;
  height: number;
  aspect?: [number, number];
  frames?: number;
}): Promise<Uint8Array> {
  const format = opts.format === "mov" ? new MovOutputFormat({ fastStart: opts.fastStart }) : new Mp4OutputFormat({ fastStart: opts.fastStart });
  const output = new Output({ format, target: new BufferTarget() });
  const source = new EncodedVideoPacketSource("avc");
  output.addVideoTrack(source);
  await output.start();
  for (let i = 0; i < (opts.frames ?? 3); i++) {
    const packet = new EncodedPacket(new Uint8Array([0, 0, 0, 1, 0x65, i, 2, 3]), i === 0 ? "key" : "delta", i / 30, 1 / 30);
    await source.add(
      packet,
      i === 0
        ? {
            decoderConfig: {
              codec: "avc1.640028",
              codedWidth: opts.width,
              codedHeight: opts.height,
              description: new Uint8Array([1, 0x64, 0, 0x28, 0xff, 0xe0, 0]),
              ...(opts.aspect ? { displayAspectWidth: opts.aspect[0], displayAspectHeight: opts.aspect[1] } : {}),
            },
          }
        : undefined,
    );
  }
  await output.finalize();
  return new Uint8Array((output.target as BufferTarget).buffer!);
}

async function engineSize(bytes: Uint8Array) {
  const input = new Input({ formats: ALL_FORMATS, source: new BufferSource(bytes) });
  const track = await input.getPrimaryVideoTrack();
  return { width: await track!.getSquarePixelWidth(), height: await track!.getSquarePixelHeight() };
}

async function apiSize(bytes: Uint8Array) {
  return readNaturalSize(async (offset, length) => bytes.slice(offset, offset + length), bytes.byteLength);
}

describe("API natural-size reader == engine demuxer", () => {
  const cases = [
    { format: "mov", fastStart: false, width: 2940, height: 1912 },
    { format: "mp4", fastStart: "in-memory", width: 1920, height: 1080 },
    { format: "mov", fastStart: false, width: 1440, height: 1080, aspect: [16, 9] },
    { format: "mp4", fastStart: false, width: 1440, height: 1080, aspect: [4, 5] },
    { format: "mp4", fastStart: "in-memory", width: 3456, height: 2234, frames: 40 },
  ] as const;
  for (const c of cases) {
    it(`${c.format} ${c.fastStart || "moov last"} ${c.width}×${c.height}${"aspect" in c ? ` DAR ${c.aspect.join(":")}` : ""}`, async () => {
      const bytes = await mux({ ...c, aspect: "aspect" in c ? [...c.aspect] : undefined });
      const engine = await engineSize(bytes);
      expect(await apiSize(bytes)).toEqual(engine);
    });
  }
});
