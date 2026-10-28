import { describe, expect, it, vi } from "vitest";

import { browserHandoffEnv, continueOnMac, continueOnMacUrl, type HandoffEnv } from "./continueOnMac";

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";

function fakeEnv(lost: boolean, log: string[]): HandoffEnv {
  return {
    open: (url) => void log.push(`open ${url}`),
    watchFocusLoss: async () => {
      log.push("watch");
      return lost;
    },
  };
}

describe("continueOnMacUrl", () => {
  it("is the Mac app's open-project deep link, marked as coming from the web", () => {
    expect(continueOnMacUrl(ID)).toBe(`capturecat://open-project?id=${ID}&from=web`);
    expect(continueOnMacUrl("a&b")).toBe("capturecat://open-project?id=a%26b&from=web");
  });
});

describe("continueOnMac", () => {
  it("saves before opening the app, and reports an opened app", async () => {
    const log: string[] = [];
    const result = await continueOnMac(ID, {
      flush: async () => void log.push("flush"),
      saved: () => true,
      env: fakeEnv(true, log),
    });
    expect(result).toBe("opened");
    // Watching starts before the link opens: the focus change can be immediate.
    expect(log).toEqual(["flush", "watch", `open capturecat://open-project?id=${ID}&from=web`]);
  });

  it("offers the download when nothing took the link", async () => {
    expect(await continueOnMac(ID, { flush: async () => {}, saved: () => true, env: fakeEnv(false, []) })).toBe("no-app");
  });

  it("never opens the Mac on an older version than the screen shows", async () => {
    const log: string[] = [];
    const result = await continueOnMac(ID, { flush: async () => {}, saved: () => false, env: fakeEnv(true, log) });
    expect(result).toBe("save-failed");
    expect(log).toEqual([]);
  });
});

describe("browserHandoffEnv", () => {
  function fakePage() {
    const win = new EventTarget() as EventTarget & { location: { href: string } };
    win.location = { href: "https://app.capturecat.so/editor/x" };
    const doc = new EventTarget() as EventTarget & { visibilityState: string };
    doc.visibilityState = "visible";
    return { win, doc, env: browserHandoffEnv(win as unknown as Window, doc as unknown as Document) };
  }

  it("navigates to the deep link", () => {
    const { win, env } = fakePage();
    env.open("capturecat://open-project?id=1&from=web");
    expect(win.location.href).toBe("capturecat://open-project?id=1&from=web");
  });

  it("resolves true on blur or a hidden page, false on timeout, and cleans up", async () => {
    vi.useFakeTimers();
    try {
      const a = fakePage();
      const blurred = a.env.watchFocusLoss(1600);
      a.win.dispatchEvent(new Event("blur"));
      expect(await blurred).toBe(true);

      const b = fakePage();
      const hidden = b.env.watchFocusLoss(1600);
      b.doc.visibilityState = "hidden";
      b.doc.dispatchEvent(new Event("visibilitychange"));
      expect(await hidden).toBe(true);

      const c = fakePage();
      const timedOut = c.env.watchFocusLoss(1600);
      vi.advanceTimersByTime(1600);
      expect(await timedOut).toBe(false);
      // A blur after the verdict changes nothing (listeners are gone).
      c.win.dispatchEvent(new Event("blur"));
      expect(await timedOut).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });
});
