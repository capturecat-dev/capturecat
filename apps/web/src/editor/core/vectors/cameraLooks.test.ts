/**
 * Golden vectors for the camera looks (docs/camera-cutout.md §10):
 *
 *   cameraLookWeights     CameraLayoutMath.lookWeights(at:regions:)
 *   cameraCutoutGeometry  CameraCutoutMath geometry (person rect, clip, card)
 *   cameraMaskCodec       a .ccmask written by the SWIFT encoder
 *                         (CameraMaskTrack.swift), decoded here: header,
 *                         per-frame key/delta + SHA-256 of the decoded alpha,
 *                         frameIndexAt lookups
 *   cameraMaskEdge        CameraMaskEdge.process (§12.4): the processed
 *                         alpha bytes, exact
 *
 * §12.10: cameraCutoutGeometry inputs carry optional popOutAmount /
 * cardBorderWidth (0…1 thickness) and its output cardBorderWidth.
 *
 * Written by `CaptureCat --web-vectors`; a missing unit FAILS (never skips).
 */
import { describe, expect, it } from "vitest";
import { checkUnit, loadVectors } from "./harness";
import * as CLM from "../math/cameraLayoutMath";
import { cutoutGeometry } from "../math/cameraCutoutMath";
import { CameraMaskDecoder, frameIndexAt, parseCameraMask } from "../mask/cameraMaskCodec";
import { processMaskEdge } from "../mask/maskEdge";
import { decodeCameraLayoutRegion } from "../model/parse";

function base64Bytes(b64: string): Uint8Array {
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

describe("camera look golden vectors", () => {
  it("cameraLookWeights", () => {
    checkUnit("cameraLookWeights", (i: { regions: unknown[]; queries: number[]; defaultLook?: "cutout" | "popOut"; stacking?: boolean }) => {
      // Regions as project.json: decoded like the Mac's Codable (lenient look,
      // unknown mode → bubble).
      const regions = i.regions.map((r, k) => decodeCameraLayoutRegion(r, `regions[${k}]`));
      // defaultLook = settings.cameraLook (the whole-video look), absent = none.
      // stacking: the vertical stack is active (§12.12) — when a case carries it.
      return { results: i.queries.map((t) => CLM.lookWeights(t, regions, i.defaultLook ?? null, i.stacking === true)) };
    });
  });

  it("cameraCutoutGeometry", () => {
    checkUnit("cameraCutoutGeometry", (i) => cutoutGeometry(i.look, i.bubbleRect, i.cameraAspect, i.popOutAmount ?? null, i.cardBorderWidth ?? null));
  });

  it("cameraMaskEdge", () => {
    checkUnit("cameraMaskEdge", (i: { width: number; height: number; base64: string; softness: number; inset: number }) => {
      const out = processMaskEdge(base64Bytes(i.base64), i.width, i.height, i.softness, i.inset);
      let raw = "";
      for (const b of out) raw += String.fromCharCode(b);
      return { base64: btoa(raw) };
    });
  });

  it("cameraMaskCodec", async () => {
    const file = loadVectors<{ base64: string; queries: number[] }>("cameraMaskCodec");
    // The decode is async (DecompressionStream); resolve every case first.
    const outputs = await Promise.all(
      file.cases.map(async ({ input }) => {
        const track = parseCameraMask(base64Bytes(input.base64));
        const decoder = new CameraMaskDecoder(track);
        const frames = [];
        for (let f = 0; f < track.header.frameCount; f++) {
          frames.push({ time: track.index[f]!.time, delta: track.index[f]!.delta, sha256: await sha256Hex(await decoder.frame(f)) });
        }
        // Random access too: a seek must land on the same bytes.
        for (let f = track.header.frameCount - 1; f >= 0; f -= 3) {
          expect(await sha256Hex(await decoder.frame(f))).toBe(frames[f]!.sha256);
        }
        return {
          header: track.header,
          frames,
          lookups: input.queries.map((t) => frameIndexAt(track.index, t)),
        };
      }),
    );
    checkUnit("cameraMaskCodec", (_input, index) => outputs[index]);
  });
});
