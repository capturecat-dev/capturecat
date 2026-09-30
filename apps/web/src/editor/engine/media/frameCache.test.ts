import { describe, expect, it } from "vitest";

import { FrameCache } from "./frameCache";

/** Just enough of a VideoFrame for the cache (it only ever closes them). */
function fakeFrame(tag: string) {
  const f = {
    tag,
    closed: false,
    close() {
      f.closed = true;
    },
  };
  return f as unknown as VideoFrame & { tag: string; closed: boolean };
}

describe("FrameCache.put", () => {
  it("replaces (and closes) an unpinned duplicate", () => {
    const cache = new FrameCache(8, 1);
    const a = fakeFrame("a");
    const b = fakeFrame("b");
    cache.put(3, a, 3);
    cache.put(3, b, 3);
    expect(cache.get(3)).toBe(b);
    expect(a.closed).toBe(true);
    expect(b.closed).toBe(false);
  });

  it("keeps a PINNED frame when its index is decoded again (the holder must never see it closed)", () => {
    const cache = new FrameCache(8, 1);
    const shown = fakeFrame("shown");
    const again = fakeFrame("again");
    cache.put(5, shown, 5);
    cache.pin(5);
    cache.put(5, again, 5);
    expect(cache.get(5)).toBe(shown);
    expect(shown.closed).toBe(false);
    expect(again.closed).toBe(true);
    expect(cache.residentBytes).toBe(1);
    // Unpinned again, a later duplicate replaces it as usual.
    cache.unpin(5);
    const later = fakeFrame("later");
    cache.put(5, later, 5);
    expect(cache.get(5)).toBe(later);
    expect(shown.closed).toBe(true);
  });
});
