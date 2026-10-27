import { describe, expect, it } from "vitest";
import {
  avatarColor,
  avatarInitial,
  buildThreads,
  groupMarkers,
  readComment,
  relativeTime,
  type ShareComment,
} from "./comments";

function c(id: string, extra: Partial<ShareComment> = {}): ShareComment {
  return {
    commentId: id,
    parentId: null,
    authorName: "Ann",
    authorImage: null,
    isOwner: false,
    body: id,
    videoTime: 0,
    createdAt: "2026-10-27T10:00:00.000Z",
    annotation: null,
    ...extra,
  };
}

describe("threads", () => {
  it("groups replies under their parent, top-level by time, replies by age", () => {
    const threads = buildThreads([
      c("b", { videoTime: 30 }),
      c("a", { videoTime: 10 }),
      c("r2", { parentId: "a", videoTime: 10, createdAt: "2026-10-27T12:00:00.000Z" }),
      c("r1", { parentId: "a", videoTime: 10, createdAt: "2026-10-27T11:00:00.000Z" }),
    ]);
    expect(threads.map((t) => t.comment.commentId)).toEqual(["a", "b"]);
    expect(threads[0].replies.map((r) => r.commentId)).toEqual(["r1", "r2"]);
    expect(threads[1].replies).toEqual([]);
  });

  it("promotes an orphaned reply instead of losing it", () => {
    const threads = buildThreads([c("r", { parentId: "gone", videoTime: 5 })]);
    expect(threads).toHaveLength(1);
    expect(threads[0].comment).toMatchObject({ commentId: "r", parentId: null });
  });
});

describe("readComment — tolerant of older API builds", () => {
  it("fills the 0031 fields when absent", () => {
    expect(
      readComment({ commentId: "x", authorName: "Bo", body: "hi", videoTime: 3, createdAt: "t" })
    ).toEqual(c("x", { authorName: "Bo", body: "hi", videoTime: 3, createdAt: "t" }));
  });

  it("never renders a non-https avatar URL", () => {
    expect(readComment({ commentId: "x", body: "b", authorImage: "javascript:alert(1)" })!.authorImage).toBeNull();
    expect(readComment({ commentId: "x", body: "b", authorImage: "http://a.test/x.png" })!.authorImage).toBeNull();
    expect(readComment({ commentId: "x", body: "b", authorImage: "https://a.test/x.png" })!.authorImage).toBe(
      "https://a.test/x.png"
    );
  });

  it("rejects garbage", () => {
    expect(readComment(null)).toBeNull();
    expect(readComment({ body: "no id" })).toBeNull();
  });
});

describe("avatars", () => {
  it("same name → same colour, case- and space-insensitive; different names usually differ", () => {
    expect(avatarColor("Mike")).toBe(avatarColor(" mike "));
    const colours = new Set(["Ann", "Bob", "Cat", "Dan", "Eve", "Fay", "Gus"].map(avatarColor));
    expect(colours.size).toBeGreaterThan(4);
  });

  it("anonymous is a neutral '?'", () => {
    expect(avatarInitial("Anonymous")).toBe("?");
    expect(avatarInitial("")).toBe("?");
    expect(avatarColor("anonymous")).toBe(avatarColor(""));
  });

  it("initial is the first character, emoji- and accent-safe", () => {
    expect(avatarInitial("mike")).toBe("M");
    expect(avatarInitial("éclair")).toBe("É");
    expect(avatarInitial("🐱 cat")).toBe("🐱");
  });
});

describe("scrubber marker grouping", () => {
  const items = (times: number[]) => times.map((time, i) => ({ id: `c${i}`, time }));

  it("keeps markers apart when they do not overlap", () => {
    const groups = groupMarkers(items([10, 30, 50]), 60, 600, 20);
    expect(groups.map((g) => g.items.length)).toEqual([1, 1, 1]);
    expect(groups.map((g) => g.ratio)).toEqual([10 / 60, 30 / 60, 50 / 60]);
  });

  it("stacks markers that would overlap, anchored at the earliest", () => {
    // 600 px for 60 s → 10 px/s; within 20 px = within 2 s of the anchor.
    const groups = groupMarkers(items([10, 11, 11.5, 30]), 60, 600, 20);
    expect(groups.map((g) => g.items.map((i) => i.id))).toEqual([["c0", "c1", "c2"], ["c3"]]);
    expect(groups[0].time).toBe(10);
    expect(groups[0].key).toBe("c0");
  });

  it("a dense run becomes several stacks, not one blob", () => {
    // One comment every second; 10 px/s, 20 px gap → stacks of two.
    const groups = groupMarkers(items([0, 1, 2, 3, 4, 5]), 60, 600, 20);
    expect(groups.map((g) => g.items.length)).toEqual([2, 2, 2]);
  });

  it("narrower tracks group more", () => {
    const wide = groupMarkers(items([10, 12, 14]), 60, 1200, 20);
    const narrow = groupMarkers(items([10, 12, 14]), 60, 200, 20);
    expect(wide.length).toBe(3);
    expect(narrow.length).toBe(1);
  });

  it("is order-independent and clamps out-of-range times", () => {
    const groups = groupMarkers(items([90, -5, 30]), 60, 600, 20);
    expect(groups.map((g) => g.ratio)).toEqual([0, 0.5, 1]);
  });

  it("zero duration puts everything in one stack at the start", () => {
    const groups = groupMarkers(items([1, 2, 3]), 0, 600, 20);
    expect(groups).toHaveLength(1);
    expect(groups[0].ratio).toBe(0);
  });
});

describe("relativeTime", () => {
  const now = Date.parse("2026-10-27T12:00:00.000Z");
  it("compact units", () => {
    expect(relativeTime("2026-10-27T11:59:50.000Z", now)).toBe("now");
    expect(relativeTime("2026-10-27T11:55:00.000Z", now)).toBe("5m");
    expect(relativeTime("2026-10-27T09:00:00.000Z", now)).toBe("3h");
    expect(relativeTime("2026-10-25T12:00:00.000Z", now)).toBe("2d");
    expect(relativeTime("nonsense", now)).toBe("");
  });
});
