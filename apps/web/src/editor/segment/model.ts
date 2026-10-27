/**
 * The portrait-matting model the browser runs to remove the webcam's
 * background (docs/camera-cutout.md §6) — the web twin of the Mac's
 * `VNGeneratePersonSegmentationRequest`.
 *
 * MODNet (`Xenova/modnet`, transformers.js `background-removal`): a trimap-
 * free portrait matting network; its processor resizes the frame to a
 * shortest edge of 512 (dims a multiple of 32) and returns a soft alpha matte.
 *
 * Weights per runtime (huggingface.co, cached by transformers.js in the
 * browser's Cache Storage — downloaded once):
 *  - WebGPU: fp32 (25.9 MB) — fp16 mattes drift on some GPUs;
 *  - WASM (no usable WebGPU adapter): the int8-quantized build, CPU-fast.
 */
export const MATTING_MODEL = "Xenova/modnet";

export type MattingDevice = "webgpu" | "wasm";

export const MATTING_DTYPE: Record<MattingDevice, string> = {
  webgpu: "fp32",
  wasm: "q8",
};

/** The model's working resolution (preprocessor_config.json `shortest_edge`). */
export const MATTING_SHORTEST_EDGE = 512;
