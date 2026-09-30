import { describe, it } from "vitest";
import { checkUnit } from "./harness";
import { frameLayout } from "../math/exportLayout";
import { staticLayout } from "../math/exportStaticLayout";

describe("layout golden vectors (device frame)", () => {
  it("exportStaticLayout", () => {
    checkUnit("exportStaticLayout", (i) => {
      const s = {
        ...i.settings,
        videoCustomX: i.settings.videoCustomX ?? undefined,
        videoCustomY: i.settings.videoCustomY ?? undefined,
      };
      const base = frameLayout(i.sourceSize, i.outputSize, s, i.canvasScale);
      return staticLayout(base, i.deviceFrameActive, s, i.canvasScale);
    });
  });
});
