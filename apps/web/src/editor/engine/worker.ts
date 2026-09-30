/**
 * Render worker entry. Owns the Engine (GPU device, OffscreenCanvas, decoders)
 * and translates the typed protocol. Loaded by `EngineClient` via
 * `new Worker(new URL("./worker.ts", import.meta.url), { type: "module" })`.
 */
import { EngineCapabilityError } from "./gpu/device";
import { Engine } from "./engine";
import { ExportCancelledError } from "./export/exporter";
import type { FromWorker, ToWorker } from "./protocol";

interface WorkerScope {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  addEventListener(type: "message", listener: (ev: MessageEvent<ToWorker>) => void): void;
}
const scope = self as unknown as WorkerScope;

const post = (msg: FromWorker, transfer: Transferable[] = []) => scope.postMessage(msg, transfer);

function reportError(err: unknown, requestId?: number) {
  const code = err instanceof EngineCapabilityError ? err.code : err instanceof ExportCancelledError ? err.code : "engine";
  const message = err instanceof Error ? err.message : String(err);
  post({ type: "error", requestId, code, message });
}

let engine: Engine | null = null;
// Messages are applied strictly in order, even across async handlers (a
// seek must never overtake the load it follows).
let chain: Promise<void> = Promise.resolve();

scope.addEventListener("message", (ev) => {
  const msg = ev.data;
  // Fresh URLs unblock reads that are waiting on an expired one — some of
  // those reads sit INSIDE the chain (a load), so never queue them behind it.
  if (msg.type === "setMediaFiles") engine?.renewMediaUrls(msg.files, { video: msg.video, expiresAt: msg.expiresAt });
  chain = chain.then(() => handle(msg)).catch((e) => reportError(e, "requestId" in msg ? msg.requestId : undefined));
});

async function handle(msg: ToWorker): Promise<void> {
  if (msg.type === "init") {
    engine = new Engine(post);
    await engine.init(msg.canvas, msg.viewport);
    return;
  }
  if (!engine) throw new Error(`engine not initialised (got ${msg.type})`);
  switch (msg.type) {
    case "load":
      await engine.load(msg.requestId, msg.project, msg.media);
      break;
    case "setProject":
      engine.setProject(msg.project);
      break;
    case "play":
      engine.play();
      break;
    case "pause":
      engine.pause();
      break;
    case "seek":
      engine.seek(msg.requestId, msg.time);
      break;
    case "rate":
      engine.setRate(msg.rate);
      break;
    case "loop":
      engine.setLoop(msg.enabled);
      break;
    case "resize":
      engine.resize(msg.viewport);
      break;
    case "clock":
      engine.syncClock(msg.mediaTime, msg.wallMs);
      break;
    case "snapshot":
      engine.snapshot(msg.requestId, !!msg.png);
      break;
    case "debug":
      engine.setDebug(msg);
      break;
    case "export":
      // Not awaited on the chain: transport/stats keep flowing during export.
      void engine.export(msg.requestId, msg.options).catch((e) => reportError(e, msg.requestId));
      break;
    case "exportCancel":
      engine.cancelExport();
      break;
    case "bench":
      await engine.bench(msg.requestId, msg.frames, msg.refit);
      break;
    case "resetStats":
      engine.resetStats();
      break;
    case "setMediaFiles":
      engine.setMediaFiles(msg.files, { video: msg.video, expiresAt: msg.expiresAt });
      break;
    case "editingAnnotation":
      engine.setEditingAnnotation(msg.id);
      break;
    case "dispose":
      engine.dispose();
      engine = null;
      break;
  }
}
