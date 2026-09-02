import { describe, it, expect } from "vitest";
import { monthKey, dayKey, consumeQuota } from "./quota";

describe("monthKey", () => {
  it("formats and pads in UTC", () => {
    expect(monthKey(new Date(Date.UTC(2026, 7, 10)))).toBe("202608");
    expect(monthKey(new Date(Date.UTC(2026, 11, 31, 23, 59)))).toBe("202612");
    expect(monthKey(new Date(Date.UTC(2027, 0, 1, 0, 0)))).toBe("202701");
  });

  it("rolls over at the UTC month boundary, not local", () => {
    // 2026-08-31T23:59:59Z vs one second later.
    expect(monthKey(new Date(Date.UTC(2026, 7, 31, 23, 59, 59)))).toBe("202608");
    expect(monthKey(new Date(Date.UTC(2026, 8, 1, 0, 0, 0)))).toBe("202609");
  });
});

describe("dayKey", () => {
  it("formats and pads in UTC, and can never collide with a month key", () => {
    expect(dayKey(new Date(Date.UTC(2026, 7, 10)))).toBe("20260810");
    expect(dayKey(new Date(Date.UTC(2026, 0, 1)))).toBe("20260101");
    expect(dayKey(new Date(Date.UTC(2026, 7, 10))).length).toBe(8);
    expect(monthKey(new Date(Date.UTC(2026, 7, 10))).length).toBe(6);
  });

  it("rolls over at UTC midnight", () => {
    expect(dayKey(new Date(Date.UTC(2026, 7, 10, 23, 59, 59)))).toBe("20260810");
    expect(dayKey(new Date(Date.UTC(2026, 7, 11, 0, 0, 0)))).toBe("20260811");
  });
});

/** In-memory stand-in reproducing the conditional-upsert semantics of
 *  CONSUME_SQL, so the quota math is testable without a Workers runtime. */
function fakeDb() {
  const rows = new Map<string, number>();
  return {
    prepare() {
      return {
        bind(userId: string, yyyymm: string, cap: number) {
          return {
            async first() {
              const k = `${userId}:${yyyymm}`;
              const current = rows.get(k);
              if (current === undefined) {
                rows.set(k, 1);
                return { count: 1 };
              }
              if (current >= cap) return null; // WHERE count < cap refused
              rows.set(k, current + 1);
              return { count: current + 1 };
            },
          };
        },
      };
    },
  } as unknown as D1Database;
}

describe("consumeQuota", () => {
  it("refuses cap <= 0 without touching the db", async () => {
    const db = { prepare: () => { throw new Error("must not query"); } } as unknown as D1Database;
    expect((await consumeQuota(db, "u1", 0)).allowed).toBe(false);
    expect((await consumeQuota(db, "u1", -5)).allowed).toBe(false);
  });

  it("counts up to the cap and then refuses without incrementing past it", async () => {
    const db = fakeDb();
    const now = new Date(Date.UTC(2026, 7, 10));
    for (let i = 1; i <= 3; i++) {
      const r = await consumeQuota(db, "u1", 3, now);
      expect(r).toEqual({ allowed: true, used: i, cap: 3 });
    }
    const over = await consumeQuota(db, "u1", 3, now);
    expect(over.allowed).toBe(false);
    expect(over.used).toBe(3); // reported at the cap, never beyond
  });

  it("meters per user and per month independently", async () => {
    const db = fakeDb();
    const aug = new Date(Date.UTC(2026, 7, 10));
    const sep = new Date(Date.UTC(2026, 8, 10));
    expect((await consumeQuota(db, "u1", 1, aug)).allowed).toBe(true);
    expect((await consumeQuota(db, "u1", 1, aug)).allowed).toBe(false);
    expect((await consumeQuota(db, "u2", 1, aug)).allowed).toBe(true); // other user
    expect((await consumeQuota(db, "u1", 1, sep)).allowed).toBe(true); // next month resets
  });
});
