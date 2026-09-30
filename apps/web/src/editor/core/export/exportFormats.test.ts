/**
 * Export formats — golden vectors from the REAL Swift
 * (`CaptureCat --export-formats-test`, Services/ExportFormats.swift), copied
 * into ./golden/exportFormats.golden.json:
 *
 *  - gifPolicy: GIFExportPolicy frame rate / delay / size / count / caption
 *  - collapse:  StaticSpanCollapse — cursor-motion timestamps, the quiet
 *               window, span scans, key quantization + equality, the
 *               camera-layout key string, the hot spans of a synthetic
 *               project (./golden/spans-project.json) and a stepped
 *               300-frame skip sequence
 *
 * plus the share markers and the still-image (PNG) frame pick.
 */
import { describe, expect, it } from "vitest";
import golden from "./golden/exportFormats.golden.json";
import spansProjectJson from "./golden/spans-project.json";
import { parseProject } from "../model";
import { newProject } from "../model/defaults";
import type { Annotation, CursorEvent } from "../model/types";
import { gifCaption, gifDelayCentiseconds, gifFrameCount, gifFrameRate, gifFrameSize, GIF_FRAME_RATES } from "./gifPolicy";
import {
  animationHotSpans,
  cameraLayoutKey,
  cursorMotionTimestamps,
  CURSOR_QUIET_WINDOW,
  exportFrameSeconds,
  inSpans,
  keysEqual,
  MAX_STATIC_GAP,
  outputHotSpans,
  quantizeKey,
  StaticSpanCollapse,
  vfrDurations,
  type StaticFrameKey,
} from "./staticSpans";
import { annotationMarkers } from "./shareMarkers";
import { defaultsToImageExport, offersImageExport, stillExportProject, stillFrameIndex } from "./stillImage";
import { animationSpeedDuration } from "../model/enums";

type Json = Record<string, unknown>;
const g = golden as unknown as { gifPolicy: Json; collapse: Json };

function toKey(j: Json): StaticFrameKey {
  const p = j.cursorPosition as { x: number; y: number } | undefined;
  return {
    videoSampleSeconds: j.videoSampleSeconds as number,
    cameraSampleSeconds: j.cameraSampleSeconds as number,
    zoom: j.zoom as number,
    focalX: j.focalX as number,
    focalY: j.focalY as number,
    offsetX: j.offsetX as number,
    offsetY: j.offsetY as number,
    tiltPitch: j.tiltPitch as number,
    tiltYaw: j.tiltYaw as number,
    tiltRoll: j.tiltRoll as number,
    cursorPosition: p ? { x: p.x, y: p.y } : null,
    cursorHidden: j.cursorHidden as boolean,
    dimAlpha: j.dimAlpha as number,
    deviceSegment: j.deviceSegment as boolean,
    cameraLayout: j.cameraLayout as string,
  };
}

describe("GIFExportPolicy (golden)", () => {
  const p = g.gifPolicy as {
    maxFrameRate: number;
    maxLongEdge: number;
    frameRates: number[];
    rates: { requested: number; frameRate: number; delayCentiseconds: number }[];
    sizes: { width: number; height: number; outWidth: number; outHeight: number }[];
    counts: { duration: number; frameRate: number; frameCount: number }[];
    captions: { width: number; height: number; fps: number; caption: string }[];
  };
  it("frame rates + delays", () => {
    expect([...GIF_FRAME_RATES]).toEqual(p.frameRates);
    for (const r of p.rates) {
      expect(gifFrameRate(r.requested), `fps ${r.requested}`).toBe(r.frameRate);
      expect(gifDelayCentiseconds(r.frameRate)).toBe(r.delayCentiseconds);
    }
  });
  it("frame sizes", () => {
    for (const s of p.sizes) {
      expect(gifFrameSize(s), `${s.width}x${s.height}`).toEqual({ width: s.outWidth, height: s.outHeight });
    }
  });
  it("frame counts", () => {
    for (const c of p.counts) expect(gifFrameCount(c.duration, c.frameRate), `${c.duration}s @ ${c.frameRate}`).toBe(c.frameCount);
  });
  it("sheet caption", () => {
    for (const c of p.captions) expect(gifCaption(c, c.fps)).toBe(c.caption);
  });
});

describe("StaticSpanCollapse (golden)", () => {
  const c = g.collapse as {
    maxStaticGap: number;
    cursorQuietWindow: number;
    cursorEvents: CursorEvent[];
    cursorTimestamps: number[];
    quietProbe: { times: number[]; quiet: boolean[]; emptyQuiet: boolean };
    spanProbe: { spans: { start: number; end: number }[]; times: number[]; inSpans: boolean[] };
    keys: Json[];
    quantized: Json[];
    equalPairs: { a: Json; b: Json; equal: boolean }[];
    cameraLayoutKeys: (Json & { key: string })[];
    hotSpans: {
      transitionDuration: number;
      keystrokeTimes: number[];
      deviceSegmentBoundaries: number[];
      animationHotSpans: { start: number; end: number }[];
      outputHotSpans: { start: number; end: number }[];
    };
    sequence: { frameCount: number; collapsedFrameCount: number; steps: { frameIndex: number; outputSeconds: number; sourceTime: number; key: Json; skip: boolean }[] };
  };

  it("constants", () => {
    expect(MAX_STATIC_GAP).toBe(c.maxStaticGap);
    expect(CURSOR_QUIET_WINDOW).toBe(c.cursorQuietWindow);
  });

  it("cursor motion timestamps + quiet window", () => {
    expect(cursorMotionTimestamps(c.cursorEvents)).toEqual(c.cursorTimestamps);
    const probe = new StaticSpanCollapse(true, [], [], c.cursorTimestamps);
    c.quietProbe.times.forEach((t, i) => expect(probe.cursorQuiet(t), `quiet @${t}`).toBe(c.quietProbe.quiet[i]));
    expect(new StaticSpanCollapse(true, [], [], []).cursorQuiet(3)).toBe(c.quietProbe.emptyQuiet);
  });

  it("span scans", () => {
    c.spanProbe.times.forEach((t, i) => expect(inSpans(c.spanProbe.spans, t), `span @${t}`).toBe(c.spanProbe.inSpans[i]));
  });

  it("key quantization + equality", () => {
    c.keys.forEach((k, i) => expect(quantizeKey(toKey(k)), `key ${i}`).toEqual(toKey(c.quantized[i])));
    c.equalPairs.forEach((pair, i) =>
      expect(keysEqual(quantizeKey(toKey(pair.a)), quantizeKey(toKey(pair.b))), `pair ${i}`).toBe(pair.equal),
    );
  });

  it("camera-layout key string (String(format:), nil rect → nan)", () => {
    for (const l of c.cameraLayoutKeys) {
      expect(
        cameraLayoutKey({
          cameraRect: (l.cameraRect as { x: number; y: number; width: number; height: number } | null) ?? null,
          cameraOpacity: l.cameraOpacity as number,
          chromeOpacity: l.chromeOpacity as number,
          cardScale: l.cardScale as number,
          cardTranslationX: l.cardTranslationX as number,
        }),
      ).toBe(l.key);
    }
  });

  it("hot spans of a synthetic project", () => {
    const project = parseProject(spansProjectJson);
    const h = c.hotSpans;
    expect(animationSpeedDuration(project.settings.animationSpeed)).toBe(h.transitionDuration);
    expect(animationHotSpans(project, h.transitionDuration, h.keystrokeTimes, h.deviceSegmentBoundaries)).toEqual(h.animationHotSpans);
    expect(outputHotSpans(project.settings)).toEqual(h.outputHotSpans);
  });

  it("stepped skip sequence", () => {
    const project = parseProject(spansProjectJson);
    const h = c.hotSpans;
    const collapser = new StaticSpanCollapse(
      true,
      animationHotSpans(project, h.transitionDuration, h.keystrokeTimes, h.deviceSegmentBoundaries),
      outputHotSpans(project.settings),
      cursorMotionTimestamps(c.cursorEvents),
    );
    for (const s of c.sequence.steps) {
      expect(collapser.shouldSkip(s.frameIndex, c.sequence.frameCount, s.outputSeconds, s.sourceTime, toKey(s.key)), `frame ${s.frameIndex}`).toBe(s.skip);
    }
    expect(collapser.collapsedFrameCount).toBe(c.sequence.collapsedFrameCount);
    // Disabled = never skip.
    const off = new StaticSpanCollapse(false, [], [], []);
    expect(c.sequence.steps.some((s) => off.shouldSkip(s.frameIndex, c.sequence.frameCount, s.outputSeconds, s.sourceTime, toKey(s.key)))).toBe(false);
  });
});

describe("VFR + frame clock", () => {
  it("frame seconds are the exporter's truncated CMTime(i / fps, 600)", () => {
    expect(exportFrameSeconds(11, 60)).toBe(109 / 600);
    expect(exportFrameSeconds(599, 60)).toBe(5989 / 600);
    expect(exportFrameSeconds(25, 30)).toBe(500 / 600);
    expect(exportFrameSeconds(20, 20)).toBe(1);
  });
  it("sample durations run to the next appended frame, the last to the timeline end", () => {
    expect(vfrDurations([0, 0.5, 2], 3)).toEqual([0.5, 1.5, 1]);
    expect(vfrDurations([0], 0.25)).toEqual([0.25]);
  });
});

describe("share markers (ExportSheetController.annotationMarkers)", () => {
  const base = newProject({ id: "8A0C2F5E-1B7D-4E6A-9C3F-2D4B6A8C0E1F", name: "m", videoURL: "file:///x/recording.mov", duration: 10 });
  const ann = (type: Annotation["type"], startTime: number, endTime: number, text = ""): Annotation =>
    ({ ...(base.annotations[0] ?? {}), id: `${type}-${startTime}`, type, startTime, endTime, text, uppercase: false }) as unknown as Annotation;
  it("output-time markers, clipped to the trim, text/callout labels only", () => {
    const p = {
      ...base,
      trimStart: 1,
      trimEnd: 9,
      annotations: [
        ann("arrow", 5, 6, "ignored"),
        ann("text", 0.5, 2, "  Hello world \n"),
        ann("callout", 8.5, 12, "x".repeat(130)),
        ann("rectangle", 9.5, 10),
      ],
    };
    const markers = annotationMarkers(p);
    expect(markers).toEqual([
      { start: 0, end: 1, label: "Hello world" },
      { start: 4, end: 5 },
      { start: 7.5, end: 8, label: "x".repeat(120) },
    ]);
  });
  it("speed regions retime markers like the exporter", () => {
    const p = { ...base, trimStart: 0, trimEnd: 10, speedRegions: [{ id: "s", startTime: 2, endTime: 4, speed: 2 }], annotations: [ann("text", 5, 6, "A")] } as never;
    expect(annotationMarkers(p)).toEqual([{ start: 4, end: 5, label: "A" }]);
  });
});

describe("still image (StillImageExporter)", () => {
  const base = newProject({ id: "8A0C2F5E-1B7D-4E6A-9C3F-2D4B6A8C0E20", name: "s", videoURL: "file:///x/recording.mov", duration: 3 });
  it("settled micro clip", () => {
    const p = stillExportProject({
      ...base,
      trimStart: 0.5,
      speedRegions: [{ id: "s", startTime: 1, endTime: 2, speed: 2 }] as never,
      settings: { ...base.settings, introSlideStyle: "Left", curtainUnveilCorner: "Top Left" },
    });
    expect(p.trimEnd).toBeCloseTo(0.7, 12);
    expect(p.speedRegions).toEqual([]);
    expect(p.videoClipSegments).toEqual([]);
    expect(p.splitPoints).toEqual([]);
    expect(p.settings.introSlideStyle).toBe("Off");
    expect(p.settings.curtainUnveilCorner).toBe("Off");
  });
  it("the PNG frame is the micro clip's last sample at or before duration − 0.01", () => {
    expect(stillFrameIndex(0.2, 60)).toBe(11);
    expect(stillFrameIndex(0.2, 30)).toBe(5);
    expect(stillFrameIndex(0.105, 60)).toBe(5);
    expect(stillFrameIndex(0.001, 60)).toBe(0);
  });
  it("Type row: stills in Image treatment; PNG unless timed effects", () => {
    const still = { ...base, isStillCapture: true, stillTreatment: "image" as const };
    expect(offersImageExport(still)).toBe(true);
    expect(defaultsToImageExport(still)).toBe(true);
    expect(defaultsToImageExport({ ...still, zoomRegions: [{} as never] })).toBe(false);
    expect(offersImageExport({ ...still, stillTreatment: "video" })).toBe(false);
    expect(offersImageExport({ ...base, isStillCapture: false, cursorDataURL: "file:///c.json" })).toBe(false);
  });
});
