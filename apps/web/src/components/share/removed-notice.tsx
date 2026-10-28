/**
 * What a share link shows after CaptureCat took the video down (admin
 * console → Videos; apps/api lib/moderation.ts). Same frame as the share
 * gate — the player's footprint — so the page keeps its shape.
 */
export function RemovedNotice({ message, compact = false }: { message: string; compact?: boolean }) {
  return (
    <div className="flex aspect-video w-full flex-col items-center justify-center rounded-xl bg-white/[0.04] ring-1 ring-white/10">
      <div className="w-full max-w-sm space-y-3 px-6 text-center">
        <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-white/[0.06] text-white/70">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-6 w-6" aria-hidden>
            <circle cx="12" cy="12" r="9" />
            <path d="M5.6 5.6l12.8 12.8" />
          </svg>
        </div>
        <h2 className="text-base font-medium text-white">Video removed</h2>
        <p className="text-sm text-white/55">{message}</p>
        {!compact && (
          <p className="text-xs text-white/35">
            If you uploaded it and think this is a mistake,{" "}
            <a href="https://capturecat.so/contact" className="underline decoration-white/25 underline-offset-4 hover:text-white/70">
              contact us
            </a>
            .
          </p>
        )}
      </div>
    </div>
  );
}
