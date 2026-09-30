import { afterEach, describe, expect, it, vi } from "vitest";

import { newProject } from "../core/model";
import { resolveFacts } from "../ui/panes/types";
import { hasShortcutEvents, keystrokeFileHasShortcuts, loadHasShortcutData } from "./recordingFacts";

const keys = (events: unknown[]) => ({ version: 1, events });

describe("hasShortcutData (InspectorColumnAppKit: keys.json events.contains { shortcut != nil })", () => {
  it("true only when some event carries a shortcut", () => {
    expect(hasShortcutEvents([{}, { shortcut: "⌘⇧S" }])).toBe(true);
    expect(hasShortcutEvents([{}, { shortcut: null }])).toBe(false);
    expect(keystrokeFileHasShortcuts(keys([{ timestamp: 1, category: "key" }, { timestamp: 2, category: "modifier", shortcut: "⌘C" }]))).toBe(true);
    expect(keystrokeFileHasShortcuts(keys([{ timestamp: 1, category: "key" }]))).toBe(false);
  });

  it("strict like JSONDecoder: one bad event = no data at all", () => {
    expect(keystrokeFileHasShortcuts(keys([{ timestamp: 1, category: "key", shortcut: "⌘C" }, { timestamp: 2, category: "bogus" }]))).toBe(false);
    expect(keystrokeFileHasShortcuts([{ timestamp: 1, category: "key", shortcut: "⌘C" }])).toBe(false);
    expect(keystrokeFileHasShortcuts(null)).toBe(false);
  });

  it("feeds the Cursor pane's gate", () => {
    const p = newProject({ duration: 5 });
    expect(resolveFacts(p).hasShortcutData).toBe(false);
    expect(resolveFacts(p, { hasShortcutData: true }).hasShortcutData).toBe(true);
  });
});

describe("loadHasShortcutData", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("fetches the project's keystroke sidecar through its media URLs", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(keys([{ timestamp: 1, category: "key", shortcut: "⌘B" }]))));
    vi.stubGlobal("fetch", fetchMock);
    const url = (ref: string | null | undefined) => (ref ? `https://media.test/${ref}?sig=1` : undefined);
    expect(await loadHasShortcutData({ keystrokeDataURL: "keys-a.json" }, url)).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith("https://media.test/keys-a.json?sig=1", { cache: "force-cache" });
  });

  it("false with no sidecar, an HTTP error, or unreadable JSON", async () => {
    const url = (ref: string | null | undefined) => (ref ? `https://media.test/${ref}` : undefined);
    expect(await loadHasShortcutData({ keystrokeDataURL: undefined }, url)).toBe(false);
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 404 })));
    expect(await loadHasShortcutData({ keystrokeDataURL: "keys-b.json" }, url)).toBe(false);
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{not json")));
    expect(await loadHasShortcutData({ keystrokeDataURL: "keys-c.json" }, url)).toBe(false);
  });
});
