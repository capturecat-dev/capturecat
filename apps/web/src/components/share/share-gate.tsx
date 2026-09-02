import { useState } from "react";

import SharePlayer, { type AnnotationMarker } from "./share-player";

/**
 * Client wall for gated shares (password / expired / view-limit).
 *
 * The server page only knows the gate state; on a correct password the API
 * hands back a short-lived HMAC token, this component refetches the full meta
 * with it and swaps in the real player, threading the token into the stream
 * and download URLs (the <video> element cannot send headers).
 */
interface OpenMeta {
  videoId: string;
  fileName: string;
  contentType: string;
  fileSizeBytes: number;
  durationSeconds: number;
  commentsEnabled?: boolean;
  allowDownload?: boolean;
  brandAccent?: string | null;
  annotations?: AnnotationMarker[];
}

export default function ShareGate({
  videoId,
  fileName,
  gate,
  brandAccent,
  apiUrl,
}: {
  videoId: string;
  fileName: string;
  gate: "locked" | "expired" | "view_limit";
  brandAccent?: string | null;
  apiUrl: string;
}) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [unlocked, setUnlocked] = useState<{ meta: OpenMeta; token: string } | null>(null);

  if (unlocked) {
    const { meta, token } = unlocked;
    const streamUrl = `${apiUrl}/api/video/${meta.videoId}?token=${token}`;
    return (
      <SharePlayer
        videoId={meta.videoId}
        videoStreamUrl={streamUrl}
        durationSeconds={meta.durationSeconds}
        commentsEnabled={meta.commentsEnabled === true}
        annotations={meta.annotations ?? []}
        brandAccent={meta.brandAccent}
        downloadUrl={
          meta.allowDownload
            ? `${apiUrl}/api/video/${meta.videoId}/download?token=${token}`
            : null
        }
      />
    );
  }

  const unlock = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(`${apiUrl}/api/video/${videoId}/unlock`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password }),
      });
      if (!res.ok) {
        setError(res.status === 429 ? "Too many attempts — try later." : "Wrong password.");
        return;
      }
      const { token } = (await res.json()) as { token: string };
      const metaRes = await fetch(
        `${apiUrl}/api/video/${videoId}/meta?token=${token}`
      );
      if (!metaRes.ok) {
        setError("Could not load the video.");
        return;
      }
      setUnlocked({ meta: (await metaRes.json()) as OpenMeta, token });
    } catch {
      setError("Network error — try again.");
    } finally {
      setBusy(false);
    }
  };

  const accent = brandAccent ?? "#FBBF24";

  return (
    <div className="flex aspect-video w-full flex-col items-center justify-center rounded-xl bg-white/[0.04] ring-1 ring-white/10">
      {gate === "locked" ? (
        <div className="w-full max-w-xs space-y-3 px-6 text-center">
          <div
            className="mx-auto grid h-12 w-12 place-items-center rounded-full"
            style={{ backgroundColor: `${accent}26`, color: accent }}
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-6 w-6">
              <rect x="5" y="11" width="14" height="9" rx="2" />
              <path d="M8 11V7a4 4 0 118 0v4" />
            </svg>
          </div>
          <h2 className="text-white text-base font-medium">{fileName}</h2>
          <p className="text-white/50 text-sm">This video is password protected.</p>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!busy && password) void unlock();
            }}
            className="flex gap-2"
          >
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="Password"
              autoFocus
              className="min-w-0 flex-1 rounded-lg bg-white/10 px-3 py-2 text-sm text-white placeholder-white/40 outline-none ring-1 ring-white/15 focus:ring-white/40"
            />
            <button
              type="submit"
              disabled={busy || password.length === 0}
              className="rounded-lg px-4 py-2 text-sm font-medium text-black transition-opacity disabled:opacity-50"
              style={{ backgroundColor: accent }}
            >
              {busy ? "…" : "Watch"}
            </button>
          </form>
          {error && <p className="text-sm text-red-400">{error}</p>}
        </div>
      ) : (
        <div className="space-y-2 px-6 text-center">
          <h2 className="text-white text-base font-medium">{fileName}</h2>
          <p className="text-white/50 text-sm">
            {gate === "expired"
              ? "This share link has expired."
              : "This video has reached its view limit."}
          </p>
        </div>
      )}
    </div>
  );
}
