import { createFileRoute } from "@tanstack/react-router";

import { ChangelogTable } from "@/components/admin/changelog-table";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/changelog")({
  component: ChangelogPage,
  head: () => ({ meta: [{ title: "Changelog — CaptureCat Admin" }] }),
});

function ChangelogPage() {
  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-2xl">Changelog</CardTitle>
          <CardDescription>
            What&rsquo;s new, as capturecat.so/changelog shows it. An entry is a
            draft, seen only here, until you publish it; then it is on the page,
            the RSS feed and the Markdown twin at once. Bodies are Markdown,
            previewed with the site&rsquo;s own renderer, so the preview is the
            page.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ChangelogTable />
        </CardContent>
      </Card>
    </div>
  );
}
