import { describe, expect, it } from "vitest";

import { superellipsePath } from "../core/math/cameraStyleMath";
import {
  BUBBLE_SIZES,
  DEFAULT_DIAMETER,
  DIAMETER_KEY,
  EDGE_MARGIN,
  POSITION_KEY,
  SHADOW_PADDING,
  SQUIRCLE_MASK_IMAGE,
  UNIT_SQUIRCLE_D,
  anchorFromRect,
  bubblePolicy,
  clampRect,
  defaultAnchor,
  isCurrentSize,
  loadAnchor,
  loadDiameter,
  panelSize,
  placeBubble,
  rectFromAnchor,
  restoreAnchor,
  saveAnchor,
  saveDiameter,
  squircleLevel,
  squirclePathD,
  type BubbleAnchor,
  type BubblePolicyInput,
  type KeyValueStore,
} from "./cameraBubble";

const VIEW = { width: 1440, height: 900 };

function memoryStore(init: Record<string, string> = {}): KeyValueStore & { data: Record<string, string> } {
  const data = { ...init };
  return {
    data,
    getItem: (k) => (k in data ? data[k] : null),
    setItem: (k, v) => {
      data[k] = v;
    },
  };
}

const throwingStore: KeyValueStore = {
  getItem: () => {
    throw new DOMException("denied", "SecurityError");
  },
  setItem: () => {
    throw new DOMException("quota", "QuotaExceededError");
  },
};

describe("metrics", () => {
  it("matches CameraFloatMetrics: 24 pt slack, sizes 150/200/270, default 200", () => {
    expect(SHADOW_PADDING).toBe(24);
    expect(panelSize(200)).toBe(248);
    expect(BUBBLE_SIZES.map((s) => [s.label, s.diameter])).toEqual([
      ["Small", 150],
      ["Medium", 200],
      ["Large", 270],
    ]);
    expect(DEFAULT_DIAMETER).toBe(200);
  });

  it("checks the current size within 1 px, like the Mac menu", () => {
    expect(isCurrentSize(200, 200)).toBe(true);
    expect(isCurrentSize(200.6, 200)).toBe(true);
    expect(isCurrentSize(201, 200)).toBe(false);
  });
});

describe("anchors", () => {
  it("round-trips a rect through its nearest-corner anchor", () => {
    const panel = panelSize(200);
    for (const rect of [
      { x: 10, y: 20, width: panel, height: panel },
      { x: 1100, y: 30, width: panel, height: panel },
      { x: 40, y: 600, width: panel, height: panel },
      { x: 1180, y: 640, width: panel, height: panel },
    ]) {
      const a = anchorFromRect(rect, VIEW);
      expect(rectFromAnchor(a, panel, VIEW)).toEqual(rect);
    }
  });

  it("picks the nearest edges", () => {
    const panel = panelSize(200);
    expect(anchorFromRect({ x: 10, y: 20, width: panel, height: panel }, VIEW)).toMatchObject({ h: "left", v: "top" });
    expect(anchorFromRect({ x: 1180, y: 640, width: panel, height: panel }, VIEW)).toEqual({ h: "right", dx: 12, v: "bottom", dy: 12 });
  });

  it("follows its corner when the viewport resizes", () => {
    const a: BubbleAnchor = { h: "right", dx: 12, v: "bottom", dy: 12 };
    const small = { width: 800, height: 600 };
    const r = placeBubble(a, 200, small).rect;
    expect(r.x + r.width).toBe(800 - 12);
    expect(r.y + r.height).toBe(600 - 12);
  });

  it("grows a size change out of the anchored corner (the pinned edges don't move)", () => {
    const a: BubbleAnchor = { h: "right", dx: 12, v: "bottom", dy: 12 };
    const small = placeBubble(a, 150, VIEW);
    const large = placeBubble(a, 270, VIEW);
    expect(small.css).toEqual({ right: 12, bottom: 12 });
    expect(large.css).toEqual({ right: 12, bottom: 12 });
    expect(large.rect.x).toBeLessThan(small.rect.x);
    const tl: BubbleAnchor = { h: "left", dx: 30, v: "top", dy: 80 };
    expect(placeBubble(tl, 150, VIEW).css).toEqual({ left: 30, top: 80 });
    expect(placeBubble(tl, 270, VIEW).css).toEqual({ left: 30, top: 80 });
  });
});

describe("clamp", () => {
  const panel = panelSize(200);

  it("keeps the squircle on-screen; only the shadow slack may spill", () => {
    const r = clampRect({ x: -500, y: 5000, width: panel, height: panel }, VIEW);
    expect(r.x).toBe(-SHADOW_PADDING);
    expect(r.y).toBe(VIEW.height - panel + SHADOW_PADDING);
    // Content (panel inset by the slack) is fully inside.
    expect(r.x + SHADOW_PADDING).toBeGreaterThanOrEqual(0);
    expect(r.y + panel - SHADOW_PADDING).toBeLessThanOrEqual(VIEW.height);
  });

  it("leaves an on-screen rect alone", () => {
    const r = { x: 300, y: 200, width: panel, height: panel };
    expect(clampRect(r, VIEW)).toEqual(r);
  });

  it("pins to the top-left when the viewport is smaller than the bubble", () => {
    const r = clampRect({ x: 50, y: 50, width: panel, height: panel }, { width: 120, height: 100 });
    expect(r).toMatchObject({ x: -SHADOW_PADDING, y: -SHADOW_PADDING });
  });

  it("re-clamps a far anchor after the window shrinks, and releases it when it grows back", () => {
    const a: BubbleAnchor = { h: "left", dx: 1000, v: "top", dy: 600 };
    const shrunk = placeBubble(a, 200, { width: 700, height: 500 });
    expect(shrunk.rect.x + panel - SHADOW_PADDING).toBeLessThanOrEqual(700);
    expect(shrunk.rect.y + panel - SHADOW_PADDING).toBeLessThanOrEqual(500);
    expect(placeBubble(a, 200, VIEW).rect).toMatchObject({ x: 1000, y: 600 });
  });
});

describe("default + restore", () => {
  const panel = panelSize(200);

  it("defaults bottom-right with a 12 px margin", () => {
    expect(defaultAnchor(panel, VIEW, null)).toEqual({ h: "right", dx: EDGE_MARGIN, v: "bottom", dy: EDGE_MARGIN });
  });

  it("stays at the bottom when the centred dock doesn't reach the corner", () => {
    const dock = { x: 370, y: 820, width: 700, height: 56 };
    expect(defaultAnchor(panel, VIEW, dock).dy).toBe(EDGE_MARGIN);
  });

  it("lifts above the dock (12 px clear) when the dock would overlap", () => {
    const view = { width: 1024, height: 768 };
    const dock = { x: 162, y: 688, width: 700, height: 56 };
    const a = defaultAnchor(panel, view, dock);
    const r = rectFromAnchor(a, panel, view);
    expect(r.y + r.height).toBe(dock.y - EDGE_MARGIN);
    expect(r.x + r.width).toBe(view.width - EDGE_MARGIN);
  });

  it("restores a saved position that is still mostly on screen", () => {
    const saved: BubbleAnchor = { h: "left", dx: 100, v: "top", dy: 100 };
    expect(restoreAnchor(saved, panel, VIEW, null)).toEqual(saved);
    // Mostly off the left edge, but the 40-inset rect still meets the viewport.
    const edge: BubbleAnchor = { h: "left", dx: -panel + 41 + 1, v: "top", dy: 100 };
    expect(restoreAnchor(edge, panel, VIEW, null)).toEqual(edge);
  });

  it("falls back to the default when the 40-inset rect no longer meets the viewport", () => {
    const gone: BubbleAnchor = { h: "left", dx: 2400, v: "top", dy: 100 };
    expect(restoreAnchor(gone, panel, VIEW, null)).toEqual(defaultAnchor(panel, VIEW, null));
    // Exactly touching after the inset doesn't count (NSRect.intersects).
    const touching: BubbleAnchor = { h: "left", dx: -panel + 40, v: "top", dy: 100 };
    expect(restoreAnchor(touching, panel, VIEW, null)).toEqual(defaultAnchor(panel, VIEW, null));
    expect(restoreAnchor(null, panel, VIEW, null)).toEqual(defaultAnchor(panel, VIEW, null));
  });
});

describe("persistence", () => {
  it("round-trips diameter and position", () => {
    const store = memoryStore();
    expect(loadDiameter(store)).toBe(200);
    saveDiameter(270, store);
    expect(store.data[DIAMETER_KEY]).toBe("270");
    expect(loadDiameter(store)).toBe(270);

    expect(loadAnchor(store)).toBeNull();
    saveAnchor({ h: "left", dx: 33.3333, v: "bottom", dy: 12 }, store);
    expect(loadAnchor(store)).toEqual({ h: "left", dx: 33.33, v: "bottom", dy: 12 });
  });

  it("ignores junk, like savedDiameter's `stored > 0`", () => {
    expect(loadDiameter(memoryStore({ [DIAMETER_KEY]: "0" }))).toBe(200);
    expect(loadDiameter(memoryStore({ [DIAMETER_KEY]: "-5" }))).toBe(200);
    expect(loadDiameter(memoryStore({ [DIAMETER_KEY]: "abc" }))).toBe(200);
    expect(loadAnchor(memoryStore({ [POSITION_KEY]: "{not json" }))).toBeNull();
    expect(loadAnchor(memoryStore({ [POSITION_KEY]: '{"h":"middle","dx":1,"v":"top","dy":1}' }))).toBeNull();
    expect(loadAnchor(memoryStore({ [POSITION_KEY]: '{"h":"left","dx":"1","v":"top","dy":1}' }))).toBeNull();
  });

  it("survives storage that throws or is missing", () => {
    expect(loadDiameter(throwingStore)).toBe(200);
    expect(loadAnchor(throwingStore)).toBeNull();
    expect(() => saveDiameter(150, throwingStore)).not.toThrow();
    expect(() => saveAnchor({ h: "left", dx: 1, v: "top", dy: 1 }, throwingStore)).not.toThrow();
    expect(loadDiameter(null)).toBe(200);
    expect(() => saveDiameter(150, null)).not.toThrow();
  });
});

describe("squircle", () => {
  it("is CameraStyleMath.superellipsePath, point for point", () => {
    const rect = { x: 0, y: 0, width: 200, height: 200 };
    const els = superellipsePath(rect);
    const d = squirclePathD(rect);
    const coords = d.match(/[ML][^MLZ]+/g) ?? [];
    expect(coords.length).toBe(256);
    expect(d.endsWith("Z")).toBe(true);
    coords.forEach((c, i) => {
      const [x, y] = c.slice(1).split(" ").map(Number);
      expect(x).toBeCloseTo(els[i].pts[0].x, 4);
      expect(y).toBeCloseTo(els[i].pts[0].y, 4);
    });
    // Starts at (maxX, midY), like the Mac path.
    expect(coords[0]).toBe("M200 100");
  });

  it("scales from the unit path exactly (the curve is affine in a, b)", () => {
    const unit = (UNIT_SQUIRCLE_D.match(/[ML][^MLZ]+/g) ?? []).map((c) => c.slice(1).split(" ").map(Number));
    const big = superellipsePath({ x: 0, y: 0, width: 270, height: 270 });
    unit.forEach(([x, y], i) => {
      expect(x * 270).toBeCloseTo(big[i].pts[0].x, 2);
      expect(y * 270).toBeCloseTo(big[i].pts[0].y, 2);
    });
    expect(SQUIRCLE_MASK_IMAGE.startsWith('url("data:image/svg+xml,')).toBe(true);
    expect(decodeURIComponent(SQUIRCLE_MASK_IMAGE)).not.toMatch(/<svg[^>]*\swidth=/);
  });

  it("is a squircle, not a circle: the diagonal boundary sits at ≈0.857 a", () => {
    const rect = { x: 0, y: 0, width: 200, height: 200 };
    // Every sampled vertex lies on the analytic curve.
    for (const el of superellipsePath(rect)) {
      if (el.op === "close") continue;
      expect(squircleLevel(el.pts[0].x, el.pts[0].y, rect)).toBeCloseTo(1, 6);
    }
    const k = Math.pow(Math.SQRT1_2, 2 / 4.5); // 0.8572…
    expect(squircleLevel(100 + 100 * k - 1, 100 + 100 * k - 1, rect)).toBeLessThan(1);
    expect(squircleLevel(100 + 100 * k + 1, 100 + 100 * k + 1, rect)).toBeGreaterThan(1);
    // A circle's boundary (0.707 a) is well inside.
    expect(squircleLevel(100 + 78, 100 + 78, rect)).toBeLessThan(1);
  });
});

describe("policy", () => {
  const base: BubblePolicyInput = { cameraOn: true, phase: "setup", surface: null, starting: false, floatingOpen: false };

  it("shows on the page while setting up with a camera on", () => {
    expect(bubblePolicy(base)).toEqual({ host: "page", hiddenForScreen: false });
    expect(bubblePolicy({ ...base, surface: "monitor" })).toEqual({ host: "page", hiddenForScreen: false });
    expect(bubblePolicy({ ...base, cameraOn: false }).host).toBe("none");
  });

  it("stays for window and tab takes", () => {
    for (const surface of ["window", "browser"] as const) {
      for (const phase of ["countdown", "recording"] as const) {
        expect(bubblePolicy({ ...base, surface, phase })).toEqual({ host: "page", hiddenForScreen: false });
      }
    }
  });

  it("hides for a whole-screen take from the moment Record is pressed", () => {
    const hidden = { host: "none", hiddenForScreen: true };
    expect(bubblePolicy({ ...base, surface: "monitor", starting: true })).toEqual(hidden);
    expect(bubblePolicy({ ...base, surface: "monitor", phase: "countdown" })).toEqual(hidden);
    expect(bubblePolicy({ ...base, surface: "monitor", phase: "recording" })).toEqual(hidden);
    // Back once the take is over (deleted → setup).
    expect(bubblePolicy({ ...base, surface: "monitor", phase: "setup" }).host).toBe("page");
  });

  it("rides in the floating controls window while it is open", () => {
    expect(bubblePolicy({ ...base, surface: "window", phase: "recording", floatingOpen: true })).toEqual({
      host: "floating",
      hiddenForScreen: false,
    });
  });

  it("is gone while the take uploads (the camera is released)", () => {
    expect(bubblePolicy({ ...base, surface: "window", phase: "saving" }).host).toBe("none");
    expect(bubblePolicy({ ...base, surface: "monitor", phase: "failed" })).toEqual({ host: "none", hiddenForScreen: false });
  });
});
