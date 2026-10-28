import { useEffect } from "react";
import { useRouter, useRouterState } from "@tanstack/react-router";

import { API_URL, SITE_URL } from "@/lib/api-url";
import { trpc } from "@/lib/trpc/client";
import { dashboardTools, registerPageTools, shareTools, siteTools, type SiteDeps } from "@/lib/webmcp";

/** Signed-in surfaces and third-party embeds: no site tools there. The
 *  editor registers its own catalog; the dashboard mounts DashboardWebMcp. */
const NO_SITE_TOOLS = /^\/(app|embed|editor-lab)(\/|$)/;

const fetchText: SiteDeps["fetchText"] = async (url, signal) => {
  const res = await fetch(url, { signal, headers: { Accept: "text/markdown, text/plain, application/json" } });
  return { ok: res.ok, status: res.status, text: await res.text() };
};

/**
 * Site-wide WebMCP: search/read/pricing/download/navigate on every public
 * page, plus `read_shared_video` on a share page. Registered on page load
 * (and re-registered when the share page changes); unregistered on leave.
 * On app.capturecat.so only the sign-in page — where every signed-out
 * visitor lands — gets them, and their navigation leaves for the marketing
 * site (the app host's router would map a site path onto the dashboard).
 */
export function SiteWebMcp() {
  const router = useRouter();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const onAppHost = typeof window !== "undefined" && window.location.host.startsWith("app.");
  const shareId = pathname.match(/^\/share\/([^/]+)$/)?.[1] ?? null;
  const enabled = onAppHost ? pathname === "/login" : !NO_SITE_TOOLS.test(pathname);

  useEffect(() => {
    if (!enabled) return;
    const deps: SiteDeps = {
      siteUrl: SITE_URL,
      apiUrl: API_URL,
      fetchText,
      navigate: onAppHost
        ? (path) => window.location.assign(new URL(path, SITE_URL).toString())
        : (path) => void router.navigate({ to: path as never }),
    };
    return registerPageTools([...siteTools(deps), ...(shareId ? shareTools(deps, shareId) : [])]);
  }, [enabled, onAppHost, shareId, router]);

  return null;
}

/** The signed-in dashboard's tools: the user's videos, analytics, account. */
export function DashboardWebMcp() {
  const router = useRouter();
  const utils = trpc.useUtils();

  useEffect(
    () =>
      registerPageTools(
        dashboardTools({
          listVideos: () => utils.videos.list.fetch(),
          searchTranscripts: (q) => utils.videos.transcriptSearch.fetch({ q }),
          videoAnalytics: (videoId) => utils.videos.analytics.fetch({ videoId }),
          account: () => utils.billing.status.fetch(),
          setPrivacy: async (videoId, isPrivate) => {
            await utils.client.videos.setPrivacy.mutate({ videoId, isPrivate });
            await utils.videos.list.invalidate();
          },
          navigate: (path) => void router.navigate({ to: path as never }),
        }),
      ),
    [utils, router],
  );

  return null;
}
