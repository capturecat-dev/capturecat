/**
 * The Free plan's recording cap: free is for personal use, and each
 * recording stops at FREE_RECORDING_SECONDS. A plan with `commercialUse`
 * (Pro, Business) records for as long as the user's own Duration Limit says.
 *
 * Same rule as the Mac's PlanGate; the number is the API's
 * FREE_RECORDING_SECONDS (apps/api/src/lib/plans.ts — planCap.test.ts reads
 * it). It lives in the clients because the server never sees a take until it
 * ends.
 */
export const FREE_RECORDING_SECONDS = 300;

/** Dev only: `localStorage["cc.dev.freeCap"] = "10"` shortens the cap to watch it work. */
function freeCap(): number {
  if (!import.meta.env.DEV) return FREE_RECORDING_SECONDS;
  try {
    const dev = Number(localStorage.getItem("cc.dev.freeCap"));
    return dev > 0 ? dev : FREE_RECORDING_SECONDS;
  } catch {
    return FREE_RECORDING_SECONDS;
  }
}

/**
 * The limit a take actually runs to, in seconds (0 = none). `userLimit` is the
 * recorder's Duration Limit pref (0 = "No Limit").
 */
export function effectiveLimit(userLimit: number, commercialUse: boolean): number {
  if (commercialUse) return userLimit;
  const cap = freeCap();
  return userLimit > 0 ? Math.min(userLimit, cap) : cap;
}

/** Whether the Free cap — not the user's own limit — is what ends the take. */
export function cappedByPlan(userLimit: number, commercialUse: boolean): boolean {
  return !commercialUse && effectiveLimit(userLimit, false) !== userLimit;
}
