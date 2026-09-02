/// <reference types="vite/client" />
import type { ReactNode } from "react";
import {
  Outlet,
  createRootRoute,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";

import { TRPCProvider } from "@/lib/trpc/client";
import { Toaster } from "@/components/ui/sonner";
import appCss from "@/styles/app.css?url";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "CaptureCat — Beautiful screen recordings" },
      {
        name: "description",
        content:
          "CaptureCat records your screen and turns it into a polished, shareable video — automatic zooms, cursor effects, and instant share links.",
      },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/favicon.ico" },
    ],
  }),
  component: RootComponent,
});

function RootComponent() {
  return (
    <RootDocument>
      <TRPCProvider>
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
