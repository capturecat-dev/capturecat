import { createFileRoute } from "@tanstack/react-router";
import { RefreshCw } from "lucide-react";

import { UsersTable } from "@/components/admin/users-table";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/users")({
  component: AdminUsersPage,
  head: () => ({ meta: [{ title: "Users — CaptureCat Admin" }] }),
});

function AdminUsersPage() {
  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6">
      <Card>
        <CardHeader className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="space-y-1">
            <CardTitle className="text-2xl">Users</CardTitle>
            <CardDescription>
              Manage tester and blocked flags. The macOS app and API resolve every request against these, so a change takes effect on the next call.
            </CardDescription>
          </div>
          <a
            href="/users"
            className="inline-flex h-9 items-center gap-2 rounded-md bg-secondary px-4 text-sm font-medium text-secondary-foreground transition-colors hover:bg-secondary/80"
          >
            <RefreshCw className="size-4" />
            Refresh
          </a>
        </CardHeader>
        <CardContent className="space-y-3">
          <UsersTable />
        </CardContent>
      </Card>
    </div>
  );
}
