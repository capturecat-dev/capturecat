import { describe, expect, it } from "vitest";

import { SeekInputGate } from "./seekGate";

describe("SeekInputGate", () => {
  it("resolves at once when every input is ready", () => {
    const gate = new SeekInputGate(1500, () => 0);
    expect(gate.ready(1, true)).toBe(true);
    expect(gate.pending).toBe(0);
  });

  it("holds a seek while the webcam frame decodes, then resolves when it lands", () => {
    let now = 0;
    const gate = new SeekInputGate(1500, () => now);
    expect(gate.ready(7, false)).toBe(false);
    now = 400;
    expect(gate.ready(7, false)).toBe(false);
    now = 420;
    expect(gate.ready(7, true)).toBe(true);
    expect(gate.pending).toBe(0);
  });

  it("gives up after the timeout, counted from the first screen-ready check", () => {
    let now = 10_000;
    const gate = new SeekInputGate(1500, () => now);
    expect(gate.ready(2, false)).toBe(false);
    now += 1499;
    expect(gate.ready(2, false)).toBe(false);
    now += 1;
    expect(gate.ready(2, false)).toBe(true);
    expect(gate.pending).toBe(0);
  });

  it("forgets superseded seeks", () => {
    const gate = new SeekInputGate(1500, () => 0);
    gate.ready(3, false);
    gate.forget(3);
    expect(gate.pending).toBe(0);
  });
});
