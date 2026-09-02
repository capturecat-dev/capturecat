/**
 * Monthly screenshot quota, metered in D1.
 *
 * One row per (user, UTC calendar month). The increment is a single
 * conditional upsert whose cap check lives INSIDE the SQL — when the cap is
 * reached the DO UPDATE's WHERE fails, no row comes back, and nothing was
 * incremented. Two concurrent requests therefore can never both consume the
 * last unit, and the counter never drifts past the cap (unlike the
 * increment-then-check shape userRateLimit uses, which is fine for rate
 * windows but not for a billed monthly allowance).
 */

/** 'YYYYMM' in UTC — pure so the rollover boundary is unit-testable. */
export function monthKey(now: Date = new Date()): string {
  const y = now.getUTCFullYear();
  const m = now.getUTCMonth() + 1;
  return `${y}${String(m).padStart(2, "0")}`;
}

/** 'YYYYMMDD' in UTC — the session (app) allowance is per-day. 8 digits, so it
 *  can never collide with the 6-digit monthly key in the same table. */
export function dayKey(now: Date = new Date()): string {
  return `${monthKey(now)}${String(now.getUTCDate()).padStart(2, "0")}`;
}

export interface QuotaResult {
  allowed: boolean;
  /** Count AFTER this request when allowed; the cap when exhausted. */
  used: number;
  cap: number;
}

export const CONSUME_SQL = `
  INSERT INTO screenshot_usage (user_id, yyyymm, count) VALUES (?1, ?2, 1)
  ON CONFLICT(user_id, yyyymm) DO UPDATE SET count = count + 1
    WHERE screenshot_usage.count < ?3
  RETURNING count`;

/**
 * Atomically consume one unit. `cap <= 0` means the plan has no allowance at
 * all (free tier) — refused without touching D1.
 * Fails CLOSED on D1 errors: a broken meter must not become unmetered renders.
 */
export async function consumeQuota(
  db: D1Database,
  userId: string,
  cap: number,
  now: Date = new Date(),
  period: "month" | "day" = "month",
): Promise<QuotaResult> {
  if (cap <= 0) return { allowed: false, used: 0, cap };
  const row = await db
    .prepare(CONSUME_SQL)
    .bind(userId, period === "day" ? dayKey(now) : monthKey(now), cap)
    .first<{ count: number }>();
  // No returned row = the conditional update was refused = cap reached.
  if (!row) return { allowed: false, used: cap, cap };
  return { allowed: true, used: row.count, cap };
}
