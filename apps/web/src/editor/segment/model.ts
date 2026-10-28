/**
 * The person-segmentation model the browser runs to remove the webcam's
 * background (docs/camera-cutout.md §6) — the web twin of the Mac's
 * `VNGeneratePersonSegmentationRequest`.
 *
 * MediaPipe's multiclass selfie segmenter (`selfie_multiclass_256x256`,
 * float32, @mediapipe/tasks-vision ImageSegmenter): made for webcam video,
 * so it holds up where portrait matting does not. Measured 2026-10-28 on a
 * real take lit by a single red lamp, beside a plant: MODNet (the model
 * before it) took the plant and the wall for the person in fp32 and kept
 * almost nothing in its int8 build — the cutout came out as scattered
 * shapes; this model kept the head, hair and shoulders cleanly. ~11 ms a
 * frame on the GPU delegate, ~150 ms on the CPU one. Person alpha =
 * 1 − its background confidence (category 0).
 *
 * Downloads (once, then Browser Cache Storage — `MODEL_CACHE`):
 *  - the model, 16.4 MB, from Google's model store, version pinned;
 *  - the tasks-vision runtime (WASM, 11 MB), the npm package's own build,
 *    from jsdelivr, version pinned to the installed package.
 */
export const SEGMENTER_MODEL_URL =
  "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite";

/** = package.json's @mediapipe/tasks-vision (the runtime must match the JS). */
export const TASKS_VISION_VERSION = "0.10.35";
const RUNTIME_BASE = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${TASKS_VISION_VERSION}/wasm`;

/** The ES-module build of the runtime: the segmenter runs in a module worker,
 *  where the classic loader's importScripts is unavailable. */
export const SEGMENTER_RUNTIME = {
  wasmLoaderPath: `${RUNTIME_BASE}/vision_wasm_module_internal.js`,
  wasmBinaryPath: `${RUNTIME_BASE}/vision_wasm_module_internal.wasm`,
} as const;

/** Cache Storage bucket for the model bytes (the runtime rides the HTTP cache). */
export const MODEL_CACHE = "capturecat-models";

/** Where it runs: the GPU delegate (WebGL in the worker), else the CPU one. */
export type MattingDevice = "gpu" | "cpu";

/** The frame size the worker hands the model (it resizes to 256×256 itself). */
export const MATTING_SHORTEST_EDGE = 360;

/**
 * Its confidence never reaches 0 on a background: on the red-lit test take
 * the room sat near 0.1 person — just over the producer dead zone, so 83 %
 * of the mask came out at the first level (14 % opacity), a ghost of the
 * room behind the cutout. A smoothstep from MATTE_LOW to MATTE_HIGH clears
 * that and keeps the soft edge; the shared producer conditioning (dead zone,
 * hold, 8 levels — core/mask/conditionAlpha.ts) runs after it unchanged.
 */
export const MATTE_LOW = 0.2;
export const MATTE_HIGH = 0.8;

/** Person alpha (0–255) from the segmenter's BACKGROUND confidence (category 0, 0–1). */
export function personAlpha(background: Float32Array, out: Uint8Array = new Uint8Array(background.length)): Uint8Array {
  const span = MATTE_HIGH - MATTE_LOW;
  for (let i = 0; i < background.length; i++) {
    const x = Math.min(1, Math.max(0, (1 - background[i]! - MATTE_LOW) / span));
    out[i] = Math.round(x * x * (3 - 2 * x) * 255);
  }
  return out;
}
