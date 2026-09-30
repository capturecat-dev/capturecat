/**
 * DEV-ONLY: bare getDisplayMedia probes — isolates what a browser (Safari)
 * accepts, outside the recorder. Each button is its own user gesture; every
 * result (name, message, track settings) is printed. /editor-lab/share-test
 */
import { useState } from "react";

type Log = { t: string; line: string };

export default function ShareTestLab() {
  const [log, setLog] = useState<Log[]>([]);
  const [live, setLive] = useState<MediaStream[]>([]);
  const add = (line: string) => setLog((l) => [...l, { t: new Date().toLocaleTimeString(), line }]);
  const report = (label: string, p: Promise<MediaStream>) => {
    const t0 = performance.now();
    p.then(
      (s) => {
        const v = s.getVideoTracks()[0];
        add(
          `${label}: OK in ${Math.round(performance.now() - t0)} ms — settings ${JSON.stringify(v?.getSettings() ?? {})} — capabilities ${JSON.stringify(v?.getCapabilities?.() ?? {})}`,
        );
        setLive((l) => [...l, s]);
      },
      (e: unknown) => add(`${label}: ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)} after ${Math.round(performance.now() - t0)} ms`),
    );
  };
  const btn = "block w-full rounded-lg border border-white/15 bg-white/[0.06] px-4 py-3 text-left text-sm hover:bg-white/[0.1]";
  return (
    <div className="dark min-h-screen bg-[#0b0b0c] p-8 text-white">
      <div className="mx-auto max-w-2xl space-y-3">
        <h1 className="text-lg font-semibold">Screen share probe</h1>
        <p className="text-sm text-white/60">Click one at a time. Pick any screen or window in the browser's picker.</p>
        <button className={btn} onClick={() => report("A · display {video:true}", navigator.mediaDevices.getDisplayMedia({ video: true }))}>
          A — getDisplayMedia({"{ video: true }"})
        </button>
        <button className={btn} onClick={() => report("B · microphone", navigator.mediaDevices.getUserMedia({ audio: true }))}>
          B — turn the microphone on (getUserMedia audio)
        </button>
        <button className={btn} onClick={() => report("C · camera", navigator.mediaDevices.getUserMedia({ video: true }))}>
          C — turn the camera on (getUserMedia video)
        </button>
        <button
          className={btn}
          onClick={() =>
            report("D · display 60fps", navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 60 } }, audio: false }))
          }
        >
          D — getDisplayMedia with a 60 fps hint (what the recorder asks)
        </button>
        <button
          className={btn}
          onClick={() => {
            live.forEach((s) => s.getTracks().forEach((t) => t.stop()));
            setLive([]);
            add("stopped every stream");
          }}
        >
          Stop everything
        </button>
        <pre className="min-h-40 whitespace-pre-wrap rounded-lg border border-white/10 bg-black/40 p-3 text-xs text-white/80">
          {log.length ? log.map((l) => `${l.t}  ${l.line}`).join("\n") : "results appear here"}
        </pre>
        <p className="text-xs text-white/40">
          {typeof navigator !== "undefined" ? navigator.userAgent : ""}
        </p>
      </div>
    </div>
  );
}
