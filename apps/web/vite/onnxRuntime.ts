/// <reference types="node" />
/**
 * Build-time resolution of ONNX Runtime Web for the editor's on-device
 * transcription worker (src/editor/transcribe/worker.ts, transformers.js).
 *
 * transformers.js imports `onnxruntime-web/webgpu`, which resolves to ORT's
 * "bundle" build. That build points at its 26 MB wasm with
 * `new URL("ort-wasm-simd-threaded.asyncify.wasm", import.meta.url)`, so Vite
 * emits the file — over Cloudflare Workers' 25 MiB static-asset limit
 * (`wrangler deploy`: "Asset too large") — although it is never loaded:
 * transformers.js sets `wasmPaths` to the version-pinned jsdelivr copy of
 * the same ORT release. ORT's own non-bundled build (its
 * "onnxruntime-web-use-extern-wasm" export condition) carries no such
 * reference; resolve to that one.
 */
import { createRequire } from "node:module";
import path from "node:path";

export function onnxRuntimeAlias(): { find: RegExp; replacement: string }[] {
  const require = createRequire(import.meta.url);
  // A file the package exports unconditionally, to locate its dist/ folder.
  const dist = path.dirname(require.resolve("onnxruntime-web/ort-wasm-simd-threaded.mjs"));
  return [{ find: /^onnxruntime-web\/webgpu$/, replacement: path.join(dist, "ort.webgpu.min.mjs") }];
}
