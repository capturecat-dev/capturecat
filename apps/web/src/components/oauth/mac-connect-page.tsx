import { useEffect, useState } from "react";

import { authClient } from "@/lib/auth-client";
import { trpc } from "@/lib/trpc/client";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
import { CCIcon } from "@/editor/ui/kit/ccIcon";

/**
 * "Allow CaptureCat for Mac to use your account?" — the native apps' sign-in
 * consent (routes/connect.mac.tsx). CaptureCat for Mac and CaptureCat for
 * iPhone and iPad both land here: the app's Sign In opens the browser on
 * api.capturecat.so/api/desktop/authorize (the iPhone app adds client=ios),
 * which records the request (PKCE, loopback redirect, which app) and sends
 * the browser here; Allow gives the app a session of its own and the API
 * hands the browser back to the app's loopback, which answers with
 * routes/connect.mac_.done.tsx. The API says which app asked
 * (`app.platform`); the Mac's copy is the default. Same card as the agent
 * consent page (components/oauth/consent-page.tsx).
 */
export function MacConnectPage({ rid, email, name }: { rid: string; email: string; name: string | null }) {
  const info = trpc.desktopConnect.info.useQuery({ rid }, { retry: false, refetchOnWindowFocus: false });
  const platform = connectPlatform(info.data?.app?.platform);
  useEffect(() => {
    // The route's <title> is the Mac's; name the app that actually asked.
    if (platform === "ios") document.title = CONNECT_COPY.ios.heading;
  }, [platform]);
  return (
    <MacConnectShell>
      {info.isLoading ? (
        <div className="space-y-4">
          <Skeleton className="h-12 w-2/3" />
          <Skeleton className="h-40 w-full" />
        </div>
      ) : info.error ? (
        <Stopped title="Can't sign in right now" description={info.error.message} platform={platform} />
      ) : info.data && !info.data.ok ? (
        <Stopped title="This sign-in link has ended" description={info.data.description} platform={platform} />
      ) : info.data ? (
        <MacConsentCard rid={rid} email={email} name={name} platform={platform} />
      ) : null}
    </MacConnectShell>
  );
}

/** Which native app is signing in. Anything but "ios" is the Mac. */
export type ConnectPlatform = "mac" | "ios";

export function connectPlatform(value: string | null | undefined): ConnectPlatform {
  return value === "ios" ? "ios" : "mac";
}

export function MacConnectShell({ children }: { children: React.ReactNode }) {
  return (
    <main className="flex min-h-screen flex-col bg-background">
      <div className="flex flex-1 items-center justify-center px-4 py-16">
        <div className="relative w-full max-w-md overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl sm:p-8">
          <span
            aria-hidden
            className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
          />
          {children}
        </div>
      </div>
    </main>
  );
}

/**
 * The app's icon with a small device badge: a laptop for "CaptureCat for
 * Mac", a phone for "CaptureCat for iPhone and iPad".
 */
export function MacAppMark({ className = "size-14", platform = "mac" }: { className?: string; platform?: ConnectPlatform }) {
  const copy = CONNECT_COPY[platform];
  return (
    <span className={`relative inline-grid shrink-0 place-items-center ${className}`}>
      <img src="/icon.png" alt={copy.appName} className="size-full rounded-[22%] shadow-lg shadow-black/30" />
      <span className="absolute -bottom-1 -right-1 grid size-6 place-items-center rounded-full border border-white/15 bg-background text-muted-foreground">
        <CCIcon name={copy.badge} size={13} />
      </span>
    </span>
  );
}

function Stopped({ title, description, platform }: { title: string; description: string; platform: ConnectPlatform }) {
  return (
    <div className="space-y-4 text-center">
      <CCIcon name="warning-fill" className="mx-auto size-6 text-cc-amber-text" />
      <h1 className="text-lg font-semibold">{title}</h1>
      <p className="text-sm text-muted-foreground">{description}</p>
      <p className="text-xs text-muted-foreground">{CONNECT_COPY[platform].tryAgain}</p>
    </div>
  );
}

const MAC_ABILITIES = [
  { icon: "cloud-upload", title: "Upload your recordings and make share links", detail: "Only the ones you choose to share" },
  { icon: "sync", title: "Sync projects with the web editor", detail: "Continue on Mac and Open in Web Editor, both ways" },
  { icon: "sparkles", title: "Use your plan", detail: "Your recording length, features and storage" },
] as const;

const IOS_ABILITIES = [
  {
    icon: "screen-record",
    title: "Stream your screen to CaptureCat for Mac",
    detail: "Over your Wi-Fi, only to Macs signed in to this account",
  },
  {
    icon: "bell",
    title: "Get asked to start streaming",
    detail: "A notification when one of your Macs asks to record this screen",
  },
] as const;

/** Everything the consent screens say that depends on which app asked. The
 *  Mac's strings are the page's original copy, unchanged. */
export const CONNECT_COPY = {
  mac: {
    appName: "CaptureCat for Mac",
    heading: "Sign in to CaptureCat for Mac",
    asker: "The Mac app",
    badge: "laptop",
    abilities: MAC_ABILITIES,
    staysSignedIn:
      "It stays signed in on this Mac until you sign out in the app. CaptureCat never sees your Google or Apple password, and signing out here doesn't sign the Mac out.",
    tryAgain: "In CaptureCat for Mac, choose Sign In again. You can close this tab.",
  },
  ios: {
    appName: "CaptureCat for iPhone and iPad",
    heading: "Sign in to CaptureCat for iPhone and iPad",
    asker: "The iPhone and iPad app",
    badge: "iphone",
    abilities: IOS_ABILITIES,
    staysSignedIn:
      "It stays signed in on this iPhone or iPad until you sign out in the app. CaptureCat never sees your Google or Apple password, and signing out here doesn't sign the app out.",
    tryAgain: "In CaptureCat on your iPhone or iPad, choose Sign In again. You can close this tab.",
  },
} as const;

export function MacConsentCard({
  rid,
  email,
  name,
  platform = "mac",
}: {
  rid: string;
  email: string;
  name: string | null;
  platform?: ConnectPlatform;
}) {
  const copy = CONNECT_COPY[platform];
  const [leaving, setLeaving] = useState<"allow" | "cancel" | "switch" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const decide = trpc.desktopConnect.decide.useMutation({
    onSuccess: (result) => {
      if (result.redirect !== null) {
        // The app's loopback: it answers with the done page.
        window.location.assign(result.redirect);
        return;
      }
      setLeaving(null);
      setError(result.error);
    },
    onError: (e) => {
      setLeaving(null);
      setError(e.message);
    },
  });
  const go = (approve: boolean) => {
    setError(null);
    setLeaving(approve ? "allow" : "cancel");
    decide.mutate({ rid, approve });
  };
  // Another account: sign this browser out, then back here through /login.
  const switchAccount = async () => {
    setLeaving("switch");
    await authClient.signOut().catch(() => {});
    window.location.assign(`/login?next=${encodeURIComponent(`/connect/mac?rid=${rid}`)}`);
  };
  const initial = (name || email).trim().charAt(0).toUpperCase() || "?";

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-center gap-4">
        <MacAppMark platform={platform} />
        <span className="flex items-center gap-1.5 text-muted-foreground" aria-hidden>
          <span className="size-1.5 rounded-full bg-current opacity-30" />
          <span className="size-1.5 rounded-full bg-current opacity-60" />
          <span className="size-1.5 rounded-full bg-current opacity-90" />
        </span>
        <span className="grid size-14 shrink-0 place-items-center rounded-full bg-primary text-xl font-semibold text-primary-foreground">
          {initial}
        </span>
      </div>

      <div className="text-center">
        <h1 className="text-xl font-semibold tracking-[-0.01em]">{copy.heading}</h1>
        <p className="mt-1.5 text-sm text-muted-foreground">
          {copy.asker} wants to use your CaptureCat account
          {name ? (
            <>
              , <span className="text-foreground">{name}</span>
            </>
          ) : null}
          .
        </p>
        <p className="mt-1 text-xs text-muted-foreground">
          {email}
          {" · "}
          <button
            type="button"
            className="underline-offset-2 hover:text-foreground hover:underline disabled:opacity-50"
            disabled={leaving !== null}
            onClick={switchAccount}
          >
            Use another account
          </button>
        </p>
      </div>

      <div className="space-y-2">
        <span className="studio-eyebrow block">It will be able to</span>
        <ul className="cc-well divide-y divide-white/5 rounded-[0.875rem]">
          {copy.abilities.map((a) => (
            <li key={a.title} className="flex items-start gap-3 px-3.5 py-3">
              <CCIcon name={a.icon} size={16} className="mt-0.5 shrink-0 text-foreground" />
              <span className="min-w-0">
                <span className="block text-sm text-foreground">{a.title}</span>
                <span className="block text-xs text-muted-foreground">{a.detail}</span>
              </span>
            </li>
          ))}
        </ul>
        <p className="flex items-start gap-1.5 text-xs text-muted-foreground">
          <CCIcon name="seal-check" size={14} className="mt-px shrink-0 text-cc-green-text" />
          <span>{copy.staysSignedIn}</span>
        </p>
      </div>

      {error && <p className="text-sm text-destructive">{error}</p>}

      <div className="flex items-center justify-end gap-2">
        <Button variant="outline" disabled={leaving !== null} onClick={() => go(false)}>
          {leaving === "cancel" && <Spinner data-icon="inline-start" />}
          Cancel
        </Button>
        <Button disabled={leaving !== null} onClick={() => go(true)}>
          {leaving === "allow" && <Spinner data-icon="inline-start" />}
          Allow
        </Button>
      </div>
    </div>
  );
}
