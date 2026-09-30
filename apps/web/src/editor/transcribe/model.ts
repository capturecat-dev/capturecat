/**
 * The speech model the browser runs — the web twin of the Mac's
 * `WhisperKit(WhisperKitConfig(model: "base.en"))`.
 *
 * SAME MODEL AS THE MAC: OpenAI Whisper base.en (74 M parameters,
 * English-only). The Mac hard-codes `base.en` and `language: "en"`, so a
 * multilingual or larger model would make the web transcribe differently
 * from the desktop for the same recording; `small` would also triple the
 * download (~480 MB at fp32) for a gain the Mac does not offer. The
 * `_timestamped` export is the ONNX build whose decoder also returns
 * cross-attentions, which Whisper's word-level timestamps (DTW over the
 * alignment heads — what WhisperKit's `wordTimestamps: true` does) need.
 *
 * Weights per runtime:
 *  - WebGPU: fp32 encoder (82.5 MB) + 4-bit decoder (123.7 MB, MatMulNBits
 *    runs on the GPU). The encoder stays fp32: fp16 Whisper encoders drift
 *    on some GPUs, and the encoder is where the timing attention comes from.
 *  - WASM (no usable WebGPU adapter): int8 encoder (23.2 MB) + int8 decoder
 *    (53.7 MB), the CPU-fast quantization.
 * Files come from huggingface.co (redirected to its CDN, *.hf.co) and are
 * kept in the browser's Cache Storage by transformers.js — downloaded once.
 */
export const WHISPER_MODEL = "onnx-community/whisper-base.en_timestamped";

export type AsrDevice = "webgpu" | "wasm";

export const WHISPER_DTYPES: Record<AsrDevice, Record<string, string>> = {
  webgpu: { encoder_model: "fp32", decoder_model_merged: "q4" },
  wasm: { encoder_model: "q8", decoder_model_merged: "q8" },
};

/** Download size (MB, rounded) of each runtime's weights — the pane's copy. */
export const WHISPER_DOWNLOAD_MB: Record<AsrDevice, number> = {
  webgpu: 210,
  wasm: 80,
};
