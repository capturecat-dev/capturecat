import { describe, expect, it } from "vitest";

import { parseProjectText, serializeProjectText } from "../core/model";
import { resolveMediaRef, type MediaUrls } from "../state/cloud";
import { mediaRef, projectDocumentFor } from "./publish";
import type { RecordedTake } from "./session";

const take = (camera: boolean): RecordedTake => ({
  id: "0B8D6C1E-3A7F-4E2B-9C5D-1F2E3A4B5C6D",
  screen: new File([new Uint8Array(8)], "recording.mov"),
  camera: camera ? new File([new Uint8Array(4)], "camera.mov") : null,
  poster: null,
  duration: 12.5,
  cameraTimeOffset: camera ? 0.04 : 0,
  surface: "window",
  sourceLabel: "Safari",
  width: 1920,
  height: 1080,
  hasSystemAudio: true,
  hasMic: true,
  folder: null,
});

describe("web take → project.json", () => {
  it("is a Mac-shaped project the core model parses back", () => {
    const text = projectDocumentFor(take(true), "Demo");
    const doc = JSON.parse(text);
    expect(doc.id).toBe(take(true).id);
    expect(doc.name).toBe("Demo");
    expect(doc.duration).toBe(12.5);
    expect(doc.cameraTimeOffset).toBe(0.04);
    expect(doc.recordingSourceKind).toBe("window");
    expect(doc.settings.showCamera).toBe(true);
    expect(doc.cursorDataURL).toBeNull();
    expect(Array.isArray(doc.zoomRegions)).toBe(true);
    expect(typeof doc.createdAt).toBe("number");
    // Lossless round trip through the core model (what the editor loads + saves).
    const parsed = parseProjectText(text);
    expect(parsed.id).toBe(take(true).id);
    expect(serializeProjectText(parsed)).toBe(text);
  });

  it("without a camera: no camera URL, camera hidden, offset 0", () => {
    const doc = JSON.parse(projectDocumentFor(take(false)));
    expect(doc.name).toBe("Untitled Recording");
    expect(doc.cameraVideoURL).toBeNull();
    expect(doc.settings.showCamera).toBe(false);
    expect(doc.cameraTimeOffset).toBe(0);
  });

  it("cuts the moments the recorder UI was on screen (non-destructively: trim + clips)", () => {
    const t = { ...take(false), surface: "monitor" as const, uiReveals: [[0, 0.6], [4, 5.2], [11.8, 12.5]] as Array<[number, number]> };
    const text = projectDocumentFor(t);
    const doc = JSON.parse(text);
    expect(doc.duration).toBe(12.5);
    expect(doc.trimStart).toBeCloseTo(0.7, 9);
    expect(doc.trimEnd).toBeCloseTo(11.7, 9);
    expect(doc.videoClipSegments.map((c: { startTime: number; endTime: number }) => [c.startTime, c.endTime])).toEqual([
      [expect.closeTo(0.7, 9), expect.closeTo(3.9, 9)],
      [expect.closeTo(5.3, 9), expect.closeTo(11.7, 9)],
    ]);
    expect(doc.splitPoints).toEqual([expect.closeTo(5.3, 9)]);
    expect(serializeProjectText(parseProjectText(text))).toBe(text);
    // A take from before uiReveals existed (a leftover's take.json) publishes uncut.
    const old = JSON.parse(projectDocumentFor(take(false)));
    expect([old.trimStart, old.trimEnd, old.videoClipSegments.length]).toEqual([0, 0, 0]);
  });

  it("media refs resolve to the uploaded logical paths", () => {
    const id = take(true).id;
    const file = (path: string) => ({ path, sha256: "x", bytes: 1, contentType: "video/quicktime", source: null, url: `https://r2/${path}` });
    const urls: Pick<MediaUrls, "media" | "sources"> = {
      media: { "recording.mov": file("recording.mov"), "camera.mov": file("camera.mov") },
      sources: {},
    };
    expect(resolveMediaRef(urls, mediaRef(id, "recording.mov"))?.path).toBe("recording.mov");
    expect(resolveMediaRef(urls, mediaRef(id, "camera.mov"))?.path).toBe("camera.mov");
  });
});
