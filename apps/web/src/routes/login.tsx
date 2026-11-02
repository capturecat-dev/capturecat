import { Link, createFileRoute, redirect } from "@tanstack/react-router";
import { z } from "zod";

import { fetchSession } from "@/lib/session-fns";
import { SignInButtons } from "@/components/dashboard/sign-in-buttons";
import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { AIR_CARD } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";

const searchSchema = z.object({
  next: z.string().optional(),
});

export const Route = createFileRoute("/login")({
  validateSearch: searchSchema,
  beforeLoad: async ({ search }) => {
    const session = await fetchSession();
    if (session) {
      const next = search.next;
      // Same-origin paths only: "//evil.com" and "/\\evil.com" both start
      // with "/" but are protocol-relative URLs — an open redirect.
      if (next && /^\/(?![\/\\])/.test(next)) {
        throw redirect({ href: next });
      }
      throw redirect({ to: "/app" });
    }
  },
  component: LoginPage,
  head: () => ({
    meta: [
      { title: "Sign in | CaptureCat" },
      {
        name: "description",
        content:
          "Sign in to CaptureCat with Google or Apple to manage your recordings and shared videos.",
      },
    ],
    links: [{ rel: "stylesheet", href: airyCss }],
  }),
});

function LoginPage() {
  const { next } = Route.useSearch();

  return (
    // The light marketing look (styles/airy.css): sign-in is reached from
    // the marketing nav, so it wears the same page as the rest of the site.
    <main data-cc-light className="relative isolate flex min-h-screen flex-col bg-background text-foreground">
      <div className="air-wash" aria-hidden />
      <div className="flex flex-1 flex-col items-center justify-center px-6 py-20">
        <Link to="/" className="mb-8 transition-opacity hover:opacity-80" aria-label="CaptureCat home">
          <CaptureCatMark className="h-12 w-12" />
        </Link>
        <div className={`${AIR_CARD} w-full max-w-md p-8`}>
          <div className="space-y-2 text-center">
            <h1 className="text-2xl font-semibold tracking-[-0.02em] text-[var(--cc-air-ink)]">Welcome to CaptureCat</h1>
            <p className="text-sm text-[var(--cc-air-muted)]">
              Sign in to manage your recordings and shared videos.
            </p>
          </div>
          <div className="mt-8">
            <SignInButtons next={next} />
          </div>
        </div>
      </div>
    </main>
  );
}
