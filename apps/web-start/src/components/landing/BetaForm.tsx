import { useCallback, useEffect, useRef, useState } from "react";

import { API_URL } from "@/lib/api-url";

/**
 * Public beta waitlist form.
 *
 * Posts straight to the API Worker (api.capturecat.so/api/beta) rather than
 * through this app, so the Worker sees the real visitor IP for its per-IP rate
 * limit — the same reason the share player posts analytics directly.
 *
 * Spam is fought server-side (honeypot + Turnstile + rate limit + email
 * dedupe); the Turnstile widget here is the client half of that.
 *
 * Turnstile SITE key is PUBLIC — it ships in every page, so a literal fallback
 * is fine when the env var is absent. The matching SECRET lives only on the API
 * Worker as TURNSTILE_SECRET and is never referenced from the browser.
 */
const SITE_KEY =
  import.meta.env.VITE_TURNSTILE_SITE_KEY ?? "0x4AAAAAAEHY2wrg5905wtMe";

// ?render=explicit stops api.js from auto-rendering `.cf-turnstile` elements,
// so our explicit render() below is the only one — no double widget.
const TURNSTILE_SRC =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";

type TurnstileAPI = {
  render: (el: HTMLElement, opts: Record<string, unknown>) => string;
  reset: (id?: string) => void;
  remove: (id?: string) => void;
};
declare global {
  interface Window {
    turnstile?: TurnstileAPI;
  }
}

type Status = "idle" | "submitting" | "success" | "error";

export function BetaForm() {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>("idle");
  const [message, setMessage] = useState<string | null>(null);

  const tokenRef = useRef<string | null>(null);
  const widgetIdRef = useRef<string | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);

  // Load api.js once and explicitly render the widget. Explicit rendering is
  // the reliable React pattern: the token arrives via callback (no racing a
  // global-named callback against hydration), and we keep a widget id so a
  // failed submit can reset() it — Turnstile tokens are single-use.
  useEffect(() => {
    let cancelled = false;

    function renderWidget() {
      if (cancelled || !window.turnstile || !containerRef.current) return;
      if (widgetIdRef.current !== null) return; // guard StrictMode double-effect
      widgetIdRef.current = window.turnstile.render(containerRef.current, {
        sitekey: SITE_KEY,
        // Telemetry attribution for the integration. Also mirrored as
        // data-action on the container div below.
        action: "turnstile-spin-v2",
        theme: "auto",
        callback: (token: string) => {
          tokenRef.current = token;
        },
        "error-callback": () => {
          tokenRef.current = null;
        },
        "expired-callback": () => {
          tokenRef.current = null;
        },
      });
    }

    if (window.turnstile) {
      renderWidget();
    } else {
      const existing = document.querySelector<HTMLScriptElement>(
        'script[src^="https://challenges.cloudflare.com/turnstile/v0/api.js"]'
      );
      if (existing) {
        existing.addEventListener("load", renderWidget, { once: true });
      } else {
        const s = document.createElement("script");
        s.src = TURNSTILE_SRC;
        s.async = true;
        s.defer = true;
        s.addEventListener("load", renderWidget, { once: true });
        document.head.appendChild(s);
      }
    }

    return () => {
      cancelled = true;
    };
  }, []);

  const resetWidget = useCallback(() => {
    if (widgetIdRef.current !== null) {
      window.turnstile?.reset(widgetIdRef.current);
      tokenRef.current = null;
    }
  }, []);

  const onSubmit = useCallback(
    async (e: React.FormEvent<HTMLFormElement>) => {
      e.preventDefault();
      if (status === "submitting") return;

      // Honeypot: real users never see or fill this. Read straight off the DOM.
      const honeypot =
        (e.currentTarget.elements.namedItem("website") as HTMLInputElement | null)
          ?.value ?? "";

      setStatus("submitting");
      setMessage(null);

      try {
        const res = await fetch(`${API_URL}/api/beta`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            email,
            website: honeypot,
            turnstileToken: tokenRef.current,
          }),
        });

        if (res.ok) {
          setStatus("success");
          return;
        }

        const data = (await res.json().catch(() => ({}))) as { error?: string };
        setStatus("error");
        setMessage(data.error ?? "Something went wrong. Please try again.");
        resetWidget(); // single-use token spent; refresh for the retry
      } catch {
        setStatus("error");
        setMessage("Network error. Please try again.");
        resetWidget();
      }
    },
    [email, status, resetWidget]
  );

  if (status === "success") {
    return (
      <div className="relative w-full max-w-md rounded-3xl border border-white/12 bg-white/[0.04] p-8 text-center shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] backdrop-blur-2xl">
        <span
          aria-hidden
          className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
        />
        <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full border border-cyan-300/40 bg-cyan-300/10 text-cyan-200">
          <svg viewBox="0 0 24 24" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth={2.2} aria-hidden>
            <path d="M20 6 9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </div>
        <h2 className="mt-5 text-2xl font-semibold tracking-[-0.02em] text-foreground">
          You&rsquo;re on the list
        </h2>
        <p className="mt-2 text-pretty text-muted-foreground">
          Thanks for signing up. We&rsquo;ll email you when your beta invite is
          ready.
        </p>
      </div>
    );
  }

  return (
    <form
      onSubmit={onSubmit}
      className="relative w-full max-w-md rounded-3xl border border-white/12 bg-white/[0.04] p-8 shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] backdrop-blur-2xl"
    >
      <span
        aria-hidden
        className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
      />

      {/* Honeypot — off-screen, not tabbable, not autofilled. A filled value is
          a bot and the server silently drops it. */}
      <div aria-hidden className="pointer-events-none absolute -left-[9999px] top-0 h-0 w-0 overflow-hidden">
        <label>
          Website
          <input type="text" name="website" tabIndex={-1} autoComplete="off" />
        </label>
      </div>

      <label htmlFor="beta-email" className="block text-sm font-medium text-foreground">
        Email address
      </label>
      <input
        id="beta-email"
        type="email"
        name="email"
        required
        autoComplete="email"
        placeholder="you@example.com"
        value={email}
        onChange={(e) => {
          setEmail(e.target.value);
          if (status === "error") {
            setStatus("idle");
            setMessage(null);
          }
        }}
        className="mt-2 h-12 w-full rounded-full border border-white/12 bg-white/[0.06] px-5 text-[15px] text-foreground outline-none backdrop-blur-xl transition-colors placeholder:text-muted-foreground focus:border-white/25 focus:bg-white/[0.09]"
      />

      {/* Turnstile widget. `cf-turnstile` + data-action satisfy the analytics
          attribution marker; the token is captured via the render callback. */}
      <div
        ref={containerRef}
        className="cf-turnstile mt-5 min-h-[65px]"
        data-action="turnstile-spin-v2"
      />

      {status === "error" && message && (
        <p role="alert" className="mt-4 text-sm text-red-300">
          {message}
        </p>
      )}

      <button
        type="submit"
        disabled={status === "submitting"}
        className="group relative mt-5 inline-flex h-12 w-full items-center justify-center gap-2 overflow-hidden rounded-full bg-white px-7 text-[15px] font-medium text-black shadow-[0_8px_30px_rgba(0,0,0,0.35)] transition-transform duration-300 hover:scale-[1.01] active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-70"
      >
        {status === "submitting" ? "Joining…" : "Join the beta"}
      </button>

      <p className="mt-4 text-center text-xs text-muted-foreground">
        No spam. We&rsquo;ll only email you about your beta access.
      </p>
    </form>
  );
}
