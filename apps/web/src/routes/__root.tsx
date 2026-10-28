/// <reference types="vite/client" />
import { useEffect, type ReactNode } from "react";
import {
  Outlet,
  createRootRoute,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";

import { TRPCProvider } from "@/lib/trpc/client";
import { Toaster } from "@/components/ui/sonner";
import { trackVisit } from "@/lib/attribution";
import { SiteWebMcp } from "@/components/webmcp/page-webmcp";
import { webmcpOriginTrialMeta } from "@/editor/webmcp/originTrial";
import appCss from "@/styles/app.css?url";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "CaptureCat: the Mac screen recorder that edits itself" },
      {
        name: "description",
        content:
          "CaptureCat records your Mac and adds the zooms, cursor smoothing, and captions automatically. Free to record and export, with share links and viewer analytics on Pro.",
      },
      // WebMCP's Chrome origin trial, on every page now that every surface
      // registers tools (see originTrial.ts for the token and its origin).
      ...webmcpOriginTrialMeta(),
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/apple-icon.png", type: "image/png" },
      // Agent discovery (src/server/agent-discovery.ts): RFC 9727 API catalog
      // and the ARD manifest, linked from every page.
      { rel: "api-catalog", href: "/.well-known/api-catalog" },
      { rel: "ai-catalog", href: "/.well-known/ai-catalog.json" },
    ],
  }),
  component: RootComponent,
});

function RootComponent() {
  // Once per page load, after hydration: an anonymous landing visit (no
  // cookie, no id — see lib/attribution.ts).
  useEffect(() => trackVisit(), []);
  return (
    <RootDocument>
      <TRPCProvider>
        <SiteWebMcp />
        <Outlet />
      </TRPCProvider>
    </RootDocument>
  );
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  return (
    // Forced dark — the product's glass language is dark-first, same as the
    // Next app's root layout.
    <html lang="en" className="dark">
      <head>
        <HeadContent />
      </head>
      <body className="min-h-screen bg-background font-sans text-foreground antialiased">
        {children}
        <Toaster position="bottom-right" />
        <Scripts />
      </body>
    </html>
  );
}
