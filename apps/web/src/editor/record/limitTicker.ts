/**
 * A steady tick while a take is live, for the Duration Limit and the Free
 * cap (planCap.ts). Not requestAnimationFrame — it stops in a hidden tab, so a
 * take recorded from another tab ran past its limit until the tab was looked
 * at again — and not a page timer, which a hidden tab throttles to once a
 * second and, after five minutes hidden, to once a minute: exactly when a
 * 5-minute cap is due. A dedicated worker's timer is not throttled with the
 * page. Where a worker can't start, a page interval is the fallback.
 */
export function startLimitTicker(onTick: () => void, everyMs = 250): () => void {
  try {
    const worker = new Worker(new URL("./limitTicker.worker.ts", import.meta.url), {
      type: "module",
      name: "capturecat-limit-ticker",
    });
    worker.onmessage = () => onTick();
    worker.postMessage(everyMs);
    return () => worker.terminate();
  } catch {
    const id = setInterval(onTick, everyMs);
    return () => clearInterval(id);
  }
}
