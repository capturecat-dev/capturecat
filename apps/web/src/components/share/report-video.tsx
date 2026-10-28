import { useState } from "react";

import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { REPORT_DETAILS_MAX, REPORT_REASONS, type ReportReason } from "@/lib/report-reasons";

/**
 * "Report video" in the share page's footer: a reason, optional details,
 * POST /api/video/:id/report (apps/api routes/video-report.ts). No account
 * needed. Reports land in the admin console's Videos → Reported queue.
 */
export function ReportVideo({ videoId, apiUrl }: { videoId: string; apiUrl: string }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [details, setDetails] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent">("idle");
  const [error, setError] = useState<string | null>(null);

  function reset(next: boolean) {
    setOpen(next);
    if (!next) {
      setReason(null);
      setDetails("");
      setState("idle");
      setError(null);
    }
  }

  async function submit() {
    if (!reason) return;
    setState("sending");
    setError(null);
    try {
      const res = await fetch(`${apiUrl}/api/video/${encodeURIComponent(videoId)}/report`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reason, details: details.trim() || null }),
      });
      if (res.ok) {
        setState("sent");
        return;
      }
      const body = (await res.json().catch(() => null)) as { error?: string; message?: string } | null;
      setError(
        res.status === 429
          ? "You've sent a lot of reports. Try again in a while."
          : (body?.message ?? body?.error ?? "Couldn't send the report. Try again."),
      );
      setState("idle");
    } catch {
      setError("Couldn't send the report. Check your connection and try again.");
      setState("idle");
    }
  }

  return (
    <>
      <button
        type="button"
        onClick={() => reset(true)}
        className="text-xs text-white/35 transition-colors hover:text-white/70"
      >
        Report video
      </button>
      <Dialog open={open} onOpenChange={reset}>
        <DialogContent className="dark gap-5 bg-[#111216] text-white ring-white/10">
          {state === "sent" ? (
            <div className="space-y-2 pr-8">
              <DialogTitle className="text-base font-medium text-white">Thanks for reporting</DialogTitle>
              <DialogDescription className="text-sm text-white/55">
                We&rsquo;ll review this video. If it breaks our rules, we&rsquo;ll take it down.
              </DialogDescription>
            </div>
          ) : (
            <>
              <div className="space-y-1 pr-8">
                <DialogTitle className="text-base font-medium text-white">Report this video</DialogTitle>
                <DialogDescription className="text-sm text-white/55">
                  What&rsquo;s wrong with it? Reports are anonymous.
                </DialogDescription>
              </div>
              <div role="radiogroup" aria-label="Reason" className="grid gap-1.5">
                {REPORT_REASONS.map((r) => (
                  <button
                    key={r.value}
                    type="button"
                    role="radio"
                    aria-checked={reason === r.value}
                    onClick={() => setReason(r.value)}
                    className={`rounded-lg px-3 py-2 text-left text-sm transition-colors ring-1 ${
                      reason === r.value
                        ? "bg-white/[0.12] text-white ring-white/30"
                        : "bg-white/[0.04] text-white/75 ring-white/10 hover:bg-white/[0.08]"
                    }`}
                  >
                    {r.label}
                  </button>
                ))}
              </div>
              <textarea
                value={details}
                onChange={(e) => setDetails(e.target.value.slice(0, REPORT_DETAILS_MAX))}
                placeholder="Anything we should know? (optional)"
                rows={3}
                className="w-full resize-none rounded-lg bg-white/[0.06] px-3 py-2 text-sm text-white placeholder-white/35 outline-none ring-1 ring-white/12 focus:ring-white/35"
              />
              {error && <p className="text-sm text-red-400">{error}</p>}
              <div className="flex justify-end gap-2">
                <button
                  type="button"
                  onClick={() => reset(false)}
                  className="rounded-lg px-4 py-2 text-sm text-white/70 transition-colors hover:bg-white/[0.06] hover:text-white"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={!reason || state === "sending"}
                  onClick={submit}
                  className="rounded-lg bg-white px-4 py-2 text-sm font-medium text-black transition-opacity disabled:opacity-40"
                >
                  {state === "sending" ? "Sending…" : "Send report"}
                </button>
              </div>
            </>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
