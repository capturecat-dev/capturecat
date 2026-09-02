import { createFileRoute, redirect } from "@tanstack/react-router";
import { z } from "zod";

import { fetchSession } from "@/lib/session-fns";
import { SignInButtons } from "@/components/dashboard/sign-in-buttons";

const searchSchema = z.object({
  next: z.string().optional(),
});

export const Route = createFileRoute("/login")({
  validateSearch: searchSchema,
  beforeLoad: async ({ search }) => {
    const session = await fetchSession();
    if (session) {
      const next = search.next;
      if (next && next.startsWith("/")) {
        throw redirect({ href: next });
      }
      throw redirect({ to: "/app" });
    }
  },
  component: LoginPage,
  head: () => ({
    meta: [
      { title: "Sign In — CaptureCat" },
      {
        name: "description",
        content:
          "Sign in to CaptureCat with Google or Apple to manage your recordings and shared videos.",
      },
    ],
  }),
});

function LoginPage() {
  const { next } = Route.useSearch();

  return (
    <main className="min-h-screen bg-background flex flex-col">
      <div className="flex-1 flex items-center justify-center px-6 py-20">
        <div className="relative w-full max-w-md overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-8 backdrop-blur-2xl">
          <span
            aria-hidden
            className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
          />
          <div className="space-y-2 text-center">
            <h1 className="text-2xl font-semibold tracking-[-0.02em]">Welcome to CaptureCat</h1>
            <p className="text-sm text-muted-foreground">
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
