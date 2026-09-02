import { createFileRoute } from "@tanstack/react-router";

import { trpc } from "@/lib/trpc/client";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export const Route = createFileRoute("/_dashboard/teams")({
  component: AdminTeamsPage,
  head: () => ({ meta: [{ title: "Teams — CaptureCat Admin" }] }),
});

function AdminTeamsPage() {
  const { data, isLoading } = trpc.admin.listOrgs.useQuery();

  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-2xl">Teams</CardTitle>
          <CardDescription>
            Organizations created through the dashboard — member counts, team
            libraries, and the owning account.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Owner</TableHead>
                  <TableHead className="text-right">Members</TableHead>
                  <TableHead className="text-right">Videos</TableHead>
                  <TableHead>Created</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(data?.orgs ?? []).map((o) => (
                  <TableRow key={o.id}>
                    <TableCell className="font-medium">{o.name}</TableCell>
                    <TableCell className="text-muted-foreground">{o.ownerEmail ?? "—"}</TableCell>
                    <TableCell className="text-right">{o.members}</TableCell>
                    <TableCell className="text-right">{o.videos}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {new Date(o.createdAt).toLocaleDateString()}
                    </TableCell>
                  </TableRow>
                ))}
                {data && data.orgs.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} className="text-center text-muted-foreground">
                      No teams yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
