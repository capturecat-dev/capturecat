import { afterEach, describe, expect, it, vi } from "vitest";

import { startLimitTicker } from "./limitTicker";

describe("the limit ticker", () => {
  afterEach(() => vi.useRealTimers());

  it("ticks steadily without animation frames, and stops when released (page-timer fallback)", () => {
    vi.useFakeTimers();
    const tick = vi.fn();
    const stop = startLimitTicker(tick, 250);
    vi.advanceTimersByTime(1000);
    expect(tick).toHaveBeenCalledTimes(4);
    stop();
    vi.advanceTimersByTime(1000);
    expect(tick).toHaveBeenCalledTimes(4);
  });
});
