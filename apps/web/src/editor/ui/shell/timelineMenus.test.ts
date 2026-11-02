/**
 * The FOCUS block menu's camera-layout entries (docs/camera-cutout.md §12.6
 * Camera on Left / Right, §12.7 Copy / Paste Layout).
 */
import { describe, expect, it } from "vitest";
import type { MenuEntry } from "../kit";
import type { ContextMenuRequest } from "../timeline/TimelineRenderer";
import type { FocusBlock, TimelineAction } from "../timeline/types";
import { timelineMenu } from "./timelineMenus";

const block = (cameraLayout?: FocusBlock["cameraLayout"]): FocusBlock => ({
  id: "R1",
  isHighlight: false,
  start: 1,
  end: 3,
  label: "Camera: Side by Side",
  selected: true,
  ...(cameraLayout ? { cameraLayout } : {}),
});

const request = (focus: FocusBlock): ContextMenuRequest => ({
  clientX: 0,
  clientY: 0,
  time: 2,
  lane: "focus",
  target: { lane: "focus", id: focus.id, isHighlight: focus.isHighlight },
  focus,
});

const titles = (entries: MenuEntry[] | null) => (entries ?? []).map((e) => (typeof e === "string" ? e : "title" in e ? e.title : `§${e.section}`));
const item = (entries: MenuEntry[] | null, title: string) =>
  (entries ?? []).find((e): e is Extract<MenuEntry, { title: string }> => typeof e !== "string" && "title" in e && e.title === title)!;

describe("camera-layout block menu", () => {
  it("Side by Side: Camera on Left / Right, Full Height / Tiles (checked), then Copy / Paste Layout", () => {
    const acts: TimelineAction[] = [];
    const entries = timelineMenu(request(block({ mode: "sideBySide", side: "leading", split: "full" })), (a) => acts.push(a), { canPasteCameraLayout: true });
    expect(titles(entries)).toEqual([
      "Camera on Left", "Camera on Right", "separator",
      "Full Height", "Tiles", "separator",
      "Copy Layout", "Paste Layout", "separator",
      "Rename…", "separator", "Delete",
    ]);
    expect(item(entries, "Camera on Left").checked).toBe(true);
    expect(item(entries, "Camera on Right").checked).toBe(false);
    expect(item(entries, "Full Height").checked).toBe(true);
    expect(item(entries, "Tiles").checked).toBe(false);
    expect(item(entries, "Paste Layout").disabled).toBe(false);
    item(entries, "Camera on Right").onSelect?.();
    item(entries, "Tiles").onSelect?.();
    item(entries, "Copy Layout").onSelect?.();
    item(entries, "Paste Layout").onSelect?.();
    expect(acts).toEqual([
      { type: "setCameraSide", regionId: "R1", side: "trailing" },
      { type: "setSplitStyle", regionId: "R1", style: "tiles" },
      { type: "copyCameraLayout", regionId: "R1" },
      { type: "pasteCameraLayout", regionId: "R1" },
    ]);
  });

  it("other modes: no side / split rows; Paste Layout disabled until something is copied", () => {
    const entries = timelineMenu(request(block({ mode: "bubble", side: "trailing", split: "tiles" })), () => {});
    expect(titles(entries)).toEqual(["Copy Layout", "Paste Layout", "separator", "Rename…", "separator", "Delete"]);
    expect(item(entries, "Paste Layout").disabled).toBe(true);
  });

  it("blur / depth-focus blocks keep their menu", () => {
    expect(titles(timelineMenu(request(block()), () => {}))).toEqual(["Rename…", "separator", "Delete"]);
  });
});
