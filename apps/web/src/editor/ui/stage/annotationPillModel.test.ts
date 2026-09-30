import { describe, expect, it } from "vitest";

import type { Annotation } from "../../core/model";
import { annotationPillOrigin, PillEdits, pillControls, pillSizeSlider } from "./annotationPillModel";

describe("annotationPillOrigin (ESVC.repositionAnnotationPill)", () => {
  const card = { width: 800, height: 450 };
  const pill = { width: 240, height: 44 };

  it("floats 10pt above the annotation, centred on it", () => {
    const o = annotationPillOrigin({ x: 300, y: 200, width: 100, height: 40 }, pill, card);
    expect(o).toEqual({ x: 350 - 120, y: 200 - 10 - 44 });
  });

  it("drops below when the headroom is under 8pt", () => {
    // top − gap − h = 60 − 10 − 44 = 6 < 8 → below: bottom edge = 100 + 10 + 44.
    const o = annotationPillOrigin({ x: 300, y: 60, width: 100, height: 40 }, pill, card);
    expect(o.y).toBe(100 + 10);
    // Exactly 8pt of headroom still goes above.
    expect(annotationPillOrigin({ x: 300, y: 62, width: 100, height: 40 }, pill, card).y).toBe(62 - 10 - 44);
  });

  it("never runs past the card bottom (8pt margin) when below", () => {
    const o = annotationPillOrigin({ x: 300, y: 20, width: 100, height: 420 }, pill, card);
    expect(o.y + pill.height).toBe(card.height - 8);
  });

  it("clamps its centre 8pt inside the card", () => {
    expect(annotationPillOrigin({ x: 0, y: 200, width: 20, height: 20 }, pill, card).x).toBe(8);
    expect(annotationPillOrigin({ x: 790, y: 200, width: 20, height: 20 }, pill, card).x).toBe(800 - 8 - 240);
  });
});

describe("pill controls (AnnotationToolbarPill.rebuildControls)", () => {
  it("per type", () => {
    expect(pillControls("text")).toEqual(["font", "weight", "divider", "backgroundToggle", "backgroundColor", "divider", "color"]);
    expect(pillControls("callout")).toEqual(pillControls("text"));
    expect(pillControls("rectangle")).toEqual(["size", "color", "divider", "backgroundToggle", "backgroundColor"]);
    expect(pillControls("arrow")).toEqual(["size", "color"]);
    expect(pillControls("tap")).toEqual(["size", "color"]);
  });
  it("size slider: ripple size for taps, line width otherwise", () => {
    expect(pillSizeSlider({ type: "tap", fontSize: 60, lineWidth: 3 })).toMatchObject({ value: 60, min: 20, max: 140 });
    expect(pillSizeSlider({ type: "rectangle", fontSize: 60, lineWidth: 3 })).toMatchObject({ value: 3, min: 1, max: 14 });
  });
});

describe("PillEdits (TimelineViewController.applyToolbar*)", () => {
  const base = (): Annotation =>
    ({
      id: "a",
      type: "text",
      fontName: "Avenir Next",
      fontWeight: "Regular",
      showBackground: false,
      color: { red: 1, green: 1, blue: 1, opacity: 1 },
      backgroundColor: { red: 0, green: 0, blue: 0, opacity: 0.6 },
      lineWidth: 3,
      fontSize: 24,
    }) as unknown as Annotation;

  it("System font is stored as nil (key omitted)", () => {
    const a = base();
    PillEdits.font(undefined)(a);
    expect("fontName" in a).toBe(false);
    PillEdits.font("New York")(a);
    expect(a.fontName).toBe("New York");
  });
  it("picking a background colour turns the background on", () => {
    const a = base();
    PillEdits.backgroundColor({ red: 1, green: 0, blue: 0, opacity: 1 })(a);
    expect(a.showBackground).toBe(true);
    expect(a.backgroundColor.red).toBe(1);
    PillEdits.toggleBackground()(a);
    expect(a.showBackground).toBe(false);
  });
  it("size writes fontSize for taps and lineWidth otherwise", () => {
    const a = base();
    PillEdits.size(7)(a);
    expect(a.lineWidth).toBe(7);
    const tap = { ...base(), type: "tap" } as Annotation;
    PillEdits.size(80)(tap);
    expect(tap.fontSize).toBe(80);
    expect(tap.lineWidth).toBe(3);
  });
});
