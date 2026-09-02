import { useState } from "react";
import { toast } from "sonner";

import { authClient } from "@/lib/auth-client";

/**
 * Sign-in is a full-page redirect to api.capturecat.so, not a popup.
 *
 * The Firebase version opened a popup, minted an ID token in the browser and
 * POSTed it to the server to be exchanged for a session cookie. Better Auth's
 * OAuth leg has to be a real navigation: it sets a `state` cookie on its own
 * response, and Apple's `response_mode=form_post` callback is a cross-site POST
 * that cannot be bridged back to an opener.
 *
 * So errors cannot be rendered in place any more — they come back on the
 * callback URL as `?error=`.
 */
export function SignInButtons({ next }: { next?: string }) {
  const [pending, setPending] = useState<string | null>(null);

  const signIn = async (provider: "google" | "apple") => {
    setPending(provider);
    const site =
      import.meta.env.VITE_SITE_URL ?? window.location.origin;
    // signIn.social resolves with { error } instead of throwing — without
    // this check a rejected request (e.g. untrusted origin) left the button
    // stuck on "Redirecting…" forever.
    const { error } = await authClient.signIn.social({
      provider,
      // Must be an absolute, trusted origin — the API origin-checks it.
      callbackURL: `${site}${next && next.startsWith("/") ? next : "/app"}`,
      errorCallbackURL: `${site}/login?error=oauth`,
    });
    if (error) {
      setPending(null);
      toast.error(error.message ?? "Sign-in failed — is the API reachable?");
    }
  };

  // Renders on the marketing /login page, so no shadcn here — the pills match
  // the Hero's buttons instead.
  return (
    <div className="flex w-full flex-col gap-3">
      <button
        type="button"
        disabled={pending !== null}
        onClick={() => signIn("google")}
        className="inline-flex h-12 w-full items-center justify-center gap-2.5 rounded-full bg-white text-[15px] font-medium text-black transition-transform duration-300 hover:scale-[1.02] active:scale-[0.99] disabled:opacity-60"
      >
        <svg className="h-[18px] w-[18px]" viewBox="0 0 24 24" aria-hidden>
          <path fill="#4285F4" d="M23.5 12.27c0-.85-.08-1.66-.22-2.45H12v4.64h6.45a5.52 5.52 0 0 1-2.39 3.62v3h3.87c2.26-2.09 3.57-5.16 3.57-8.81z" />
          <path fill="#34A853" d="M12 24c3.24 0 5.96-1.07 7.94-2.91l-3.87-3c-1.07.72-2.45 1.15-4.07 1.15-3.13 0-5.78-2.11-6.73-4.96H1.29v3.1A12 12 0 0 0 12 24z" />
          <path fill="#FBBC05" d="M5.27 14.28A7.2 7.2 0 0 1 4.9 12c0-.79.14-1.56.37-2.28v-3.1H1.29a12 12 0 0 0 0 10.76l3.98-3.1z" />
          <path fill="#EA4335" d="M12 4.76c1.76 0 3.34.6 4.59 1.79l3.44-3.44A11.97 11.97 0 0 0 12 0 12 12 0 0 0 1.29 6.62l3.98 3.1C6.22 6.87 8.87 4.76 12 4.76z" />
        </svg>
        {pending === "google" ? "Redirecting…" : "Continue with Google"}
      </button>
      <button
        type="button"
        disabled={pending !== null}
        onClick={() => signIn("apple")}
        className="inline-flex h-12 w-full items-center justify-center gap-2.5 rounded-full border border-white/12 bg-white/[0.06] text-[15px] font-medium text-foreground backdrop-blur-xl transition-colors duration-300 hover:border-white/20 hover:bg-white/[0.10] disabled:opacity-60"
      >
        <svg className="h-[18px] w-[18px]" viewBox="0 0 842.32 1000" fill="currentColor" aria-hidden>
          <path d="M824.66636 779.30363c-15.12299 34.93724-33.02368 67.09674-53.7638 96.66374-28.27076 40.3074-51.4182 68.2078-69.25717 83.7012-27.65347 25.4313-57.2822 38.4556-89.00964 39.1963-22.77708 0-50.24539-6.4813-82.21973-19.629-32.07926-13.0861-61.55985-19.5673-88.51583-19.5673-28.27075 0-58.59083 6.4812-91.02193 19.5673-32.48053 13.1477-58.64639 19.9994-78.65196 20.6784-30.42501 1.29623-60.75123-12.0985-91.02193-40.2457-19.32039-16.8514-43.48632-45.7394-72.43607-86.6641-31.060778-43.7024-56.597041-94.37983-76.602609-152.15586C10.740416 658.44309 0 598.01283 0 539.50845c0-67.01648 14.481044-124.8172 43.486336-173.25401C66.28194 327.34823 96.60818 296.6578 134.5638 274.1276c37.95566-22.53016 78.96676-34.01129 123.1321-34.74585 24.16591 0 55.85633 7.47508 95.23784 22.166 39.27042 14.74029 64.48571 22.21538 75.54091 22.21538 8.26518 0 36.27668-8.7405 83.7629-26.16587 44.90607-16.16001 82.80614-22.85118 113.85458-20.21546 84.13326 6.78992 147.34122 39.95559 189.37699 99.70686-75.24463 45.59122-112.46573 109.4473-111.72502 191.36456.67899 63.8067 23.82643 116.90384 69.31888 159.06309 20.61664 19.56727 43.64066 34.69027 69.2571 45.4307-5.55531 16.11062-11.41933 31.54225-17.65372 46.35662zM631.70926 20.0057c0 50.01141-18.27108 96.70693-54.6897 139.92782-43.94932 51.38118-97.10817 81.07162-154.75459 76.38659-.73454-5.99983-1.16045-12.31444-1.16045-18.95003 0-48.01091 20.9006-99.39207 58.01678-141.40314 18.53027-21.27094 42.09746-38.95744 70.67685-53.0663C578.3158 9.00229 605.2903 1.31621 630.65988 0c.74076 6.68575 1.04938 13.37191 1.04938 20.00505z" />
        </svg>
        {pending === "apple" ? "Redirecting…" : "Continue with Apple"}
      </button>
    </div>
  );
}
