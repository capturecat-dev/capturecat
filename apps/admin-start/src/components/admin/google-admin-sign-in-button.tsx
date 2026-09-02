import { useState } from "react";
import { Button } from "@/components/ui/button";
import { authClient } from "@/lib/auth-client";

/**
 * There is no separate admin sign-in any more.
 *
 * Admin used to be its own credential: a distinct 7-day cookie minted only
 * after an ID token was checked against an allowlist. Better Auth issues one
 * session, and admin-ness is `user.role === "admin"` on it — so this is an
 * ordinary sign-in that happens to land on the admin console, and a non-admin
 * who reaches it is bounced by the server guard.
 */
export function GoogleAdminSignInButton() {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  return (
    <>
    <Button
      className="w-full"
      disabled={pending}
      onClick={async () => {
        setPending(true);
        setError(null);
        const site = import.meta.env.VITE_SITE_URL ?? window.location.origin;
        try {
          // Resolves with { error } for a rejected request (e.g. untrusted
          // origin) — only network failures actually throw.
          const { error: authError } = await authClient.signIn.social({
            provider: "google",
            callbackURL: `${site}/`,
            errorCallbackURL: `${site}/login?error=oauth`,
          });
          if (authError) {
            setError(authError.message ?? "Sign-in was rejected.");
            setPending(false);
          }
        } catch {
          // A fetch to an unreachable auth host throws a bare
          // `TypeError: Load failed`, which names neither the host nor the
          // reason. Say which URL failed — in dev that is almost always the
          // API worker not running, or VITE_API_URL still pointing at a
          // host that has not been deployed yet.
          const api = import.meta.env.VITE_API_URL ?? "https://api.capturecat.so";
          setError(`Could not reach the auth server at ${api}.`);
          setPending(false);
        }
      }}
    >
      {pending ? "Redirecting…" : "Continue with Google"}
    </Button>
    {error && (
      <p className="mt-3 text-sm text-destructive">{error}</p>
    )}
    </>
  );
}
