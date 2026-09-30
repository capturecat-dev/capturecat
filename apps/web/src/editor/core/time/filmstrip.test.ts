/**
 * core/time/filmstrip.ts — hand-derived vectors from TimelineThumbnailer.swift and
 * VideoTrackRowNative.drawVideoFilmstrip (count/spacing/stamping, nearest lookup, the
 * tile walk incl. device crops, trimmed/sped-up source spans and timeline zoom).
 */
import { describe, expect, it } from "vitest";
import {
  deviceContentRectAt,
  filmstripFrameTime,
  filmstripPixelHeight,
  filmstripRequestTimes,
  layoutFilmstrip,
  nearestThumbnailIndex,
  type FilmstripThumb,
} from "./filmstrip";

const thumbsFor = (duration: number, w = 171, h = 96): FilmstripThumb[] =>
  filmstripRequestTimes(duration).map((time) => ({ time, width: w, height: h }));

describe("filmstripRequestTimes (TimelineThumbnailer.generate)", () => {
  it("40 requests at (i + 0.5)·duration/40, CMTime(600)-truncated", () => {
    const t = filmstripRequestTimes(40);
    expect(t.length).toBe(40);
    expect(t[0]).toBe(0.5);
    expect(t[39]).toBe(39.5);
    // 10 s: stride 0.25 → 0.125 = 75/600 exactly; 7 s: stride 0.175 → 0.0875·600 = 52.5 → 52/600.
    expect(filmstripRequestTimes(10)[0]).toBe(75 / 600);
    expect(filmstripRequestTimes(7)[0]).toBe(52 / 600);
    for (const d of [0.3, 7, 44.668, 307.24]) {
      for (const [i, v] of filmstripRequestTimes(d).entries()) {
        expect(v).toBe(Math.trunc((i + 0.5) * (d / 40) * 600) / 600);
      }
    }
  });
  it("nothing for an empty recording", () => {
    expect(filmstripRequestTimes(0)).toEqual([]);
    expect(filmstripRequestTimes(-1)).toEqual([]);
    expect(filmstripRequestTimes(10, 0)).toEqual([]);
  });
  it("96 px at 2× (maximumSize), scaled with devicePixelRatio", () => {
    expect(filmstripPixelHeight(2)).toBe(96);
    expect(filmstripPixelHeight(1)).toBe(48);
    expect(filmstripPixelHeight(3)).toBe(144);
    expect(filmstripPixelHeight(1.25)).toBe(60);
    expect(filmstripPixelHeight(Number.NaN)).toBe(48);
  });
});

describe("nearestThumbnailIndex (TimelineThumbnailer.thumbnail(at:in:))", () => {
  it("nearest by |Δt|, first of equals wins, −1 when empty", () => {
    const times = [0.5, 1.5, 2.5];
    expect(nearestThumbnailIndex(times, 0)).toBe(0);
    expect(nearestThumbnailIndex(times, 1.0)).toBe(0); // tie 0.5 / 1.5 → first
    expect(nearestThumbnailIndex(times, 1.01)).toBe(1);
    expect(nearestThumbnailIndex(times, 99)).toBe(2);
    expect(nearestThumbnailIndex([], 1)).toBe(-1);
  });
});

describe("filmstripFrameTime (AVAssetImageGenerator ±0.5 s tolerance)", () => {
  const fps = 30;
  const pts = Array.from({ length: 300 }, (_, i) => i / fps);
  const keyPts = pts.filter((_, i) => i % 60 === 0); // a key every 2 s
  it("snaps to the nearest keyframe inside the window", () => {
    expect(filmstripFrameTime(2.3, pts, keyPts)).toBe(2);
    expect(filmstripFrameTime(3.7, pts, keyPts)).toBe(4);
    expect(filmstripFrameTime(3.0, pts, keyPts, 1.0)).toBe(2); // keys 2 and 4 tie → the earlier
  });
  it("else stops at the first frame of the window", () => {
    expect(filmstripFrameTime(1.0, pts, keyPts)).toBe(pts[15]); // window starts at 0.5 → frame 15
    expect(filmstripFrameTime(5.0, pts, keyPts)).toBe(pts[135]);
  });
  it("falls back to the frame on screen when the window is empty", () => {
    expect(filmstripFrameTime(50, pts, keyPts)).toBe(pts[299]);
    expect(Number.isNaN(filmstripFrameTime(1, [], []))).toBe(true);
  });
});

describe("layoutFilmstrip (drawVideoFilmstrip)", () => {
  const thumbs = thumbsFor(40); // times 0.5 … 39.5, 171×96
  const aspect = 171 / 96;

  it("tiles from the rect's left edge at height × aspect, probing each tile's centre", () => {
    const rect = { x: 100, width: 400, height: 48 };
    const tiles = layoutFilmstrip(rect, 0, 40, thumbs);
    const tw = 48 * aspect;
    expect(tiles.length).toBe(Math.ceil(400 / tw));
    tiles.forEach((t, k) => {
      expect(t.x).toBeCloseTo(100 + k * tw, 9);
      expect(t.width).toBeCloseTo(tw, 12);
      expect(t.time).toBeCloseTo(((k * tw + tw / 2) / 400) * 40, 9);
      expect(t.index).toBe(nearestThumbnailIndex(thumbs.map((x) => x.time), t.time));
      expect(t.crop).toBeNull();
    });
  });

  it("maps a trimmed / sped-up clip's SOURCE span linearly across its drawn rect", () => {
    // A clip showing source 10…20 s squeezed (2× speed) into a 120 px rect.
    const tiles = layoutFilmstrip({ x: 0, width: 120, height: 48 }, 10, 20, thumbs);
    const tw = 48 * aspect;
    expect(tiles[0].time).toBeCloseTo(10 + (tw / 2 / 120) * 10, 9);
    expect(tiles[0].index).toBe(13); // 10 + 42.75/120 · 10 = 13.56 s → the 13.5 s thumbnail
    expect(tiles.at(-1)!.time).toBeLessThanOrEqual(20 + 10 * (tw / 2 / 120));
  });

  it("timeline zoom re-tiles: a wider rect probes more (nearer) thumbnails", () => {
    const narrow = layoutFilmstrip({ x: 0, width: 300, height: 48 }, 0, 40, thumbs);
    const wide = layoutFilmstrip({ x: 0, width: 300 * 8, height: 48 }, 0, 40, thumbs);
    expect(wide.length).toBeGreaterThan(narrow.length * 7);
    expect(new Set(wide.map((t) => t.index)).size).toBeGreaterThan(new Set(narrow.map((t) => t.index)).size);
    // Same tile phase: tile k starts at k × tile width in both.
    expect(wide[3].x).toBeCloseTo(narrow[3].x, 9);
  });

  it("stopX ends the walk without changing the tiles before it", () => {
    const all = layoutFilmstrip({ x: 0, width: 5000, height: 48 }, 0, 40, thumbs);
    const head = layoutFilmstrip({ x: 0, width: 5000, height: 48 }, 0, 40, thumbs, undefined, 800);
    expect(head.length).toBeLessThan(all.length);
    expect(head).toEqual(all.slice(0, head.length));
    expect(head.at(-1)!.x).toBeLessThan(800);
  });

  it("device segments crop to the content rect (integral) and tile at its aspect", () => {
    const segments = [
      { startTime: 0, duration: 20, kind: "device" as const, contentX: 0.25, contentY: 0.1, contentWidth: 0.3, contentHeight: 0.8 },
      { startTime: 20, duration: 20, kind: "display" as const, contentX: 0, contentY: 0, contentWidth: 1, contentHeight: 1 },
    ];
    const tiles = layoutFilmstrip({ x: 0, width: 1000, height: 48 }, 0, 40, thumbs, segments);
    const device = tiles.filter((t) => t.time <= 20);
    const screen = tiles.filter((t) => t.time > 20);
    expect(device.length).toBeGreaterThan(0);
    for (const t of device) {
      // 171×96 · (0.25, 0.1, 0.3, 0.8) = (42.75, 9.6, 51.3, 76.8) → integral (42, 9)…(95, 87).
      expect(t.crop).toEqual({ x: 42, y: 9, width: 53, height: 78 });
      expect(t.width).toBeCloseTo(48 * ((0.3 * 171) / (0.8 * 96)), 9);
    }
    for (const t of screen) expect(t.crop).toBeNull();
    expect(deviceContentRectAt(segments, 20)).not.toBeNull(); // closed interval
    expect(deviceContentRectAt(segments, 20.0001)).toBeNull();
  });

  it("minimum tile / probe widths (10 / 12) and empty inputs", () => {
    const tall = [{ time: 1, width: 1, height: 400 }];
    const tiles = layoutFilmstrip({ x: 0, width: 50, height: 40 }, 0, 2, tall);
    expect(tiles.every((t) => t.width === 10)).toBe(true);
    expect(tiles[0].time).toBeCloseTo((6 / 50) * 2, 12);
    expect(layoutFilmstrip({ x: 0, width: 50, height: 40 }, 0, 2, [])).toEqual([]);
    expect(layoutFilmstrip({ x: 0, width: 0, height: 40 }, 0, 2, tall)).toEqual([]);
  });
});
