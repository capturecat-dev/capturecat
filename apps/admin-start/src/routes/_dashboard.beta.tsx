import { createFileRoute } from "@tanstack/react-router";
import { RefreshCw } from "lucide-react";

import { BetaTable } from "@/components/admin/beta-table";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/beta")({
  component: AdminBetaPage,
  head: () => ({ meta: [{ title: "Beta — CaptureCat Admin" }] }),
});

function AdminBetaPage() {
  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6">
      <Card>
        <CardHeader className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="space-y-1">
            <CardTitle className="text-2xl">Beta signups</CardTitle>
            <CardDescription>
              Emails collected from the public <code>/beta</code> page. Each one
              cleared a honeypot, Cloudflare Turnstile, and a per-IP rate limit —
              delete anything that still looks like spam.
            </CardDescription>
          </div>
          <a
            href="/beta"
            className="inline-flex h-9 items-center gap-2 rounded-md bg-secondary px-4 text-sm font-medium text-secondary-foreground transition-colors hover:bg-secondary/80"
          >
            <RefreshCw className="size-4" />
            Refresh
          </a>
        </CardHeader>
        <CardContent className="space-y-3">
          <BetaTable />
        </CardContent>
      </Card>
    </div>
  );
}
