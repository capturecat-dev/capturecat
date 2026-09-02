import { useState } from "react";
import { Check, Copy, Trash2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { trpc } from "@/lib/trpc/client";
import { TableLoading } from "@/components/ui/table-loading";

type BetaSignup = {
  id: string;
  email: string;
  status: string;
  ip: string | null;
  userAgent: string | null;
  referrer: string | null;
  country: string | null;
  createdAt: string;
};

function formatDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString();
}

export function BetaTable() {
  const { data, isLoading } = trpc.admin.listBetaSignups.useQuery();
  const utils = trpc.useUtils();
  const del = trpc.admin.deleteBetaSignup.useMutation({
    onSuccess: () => utils.admin.listBetaSignups.invalidate(),
  });
  const [copied, setCopied] = useState(false);

  if (isLoading) return <TableLoading />;
  const signups: BetaSignup[] = data?.signups ?? [];

  const copyEmails = async () => {
    try {
      await navigator.clipboard.writeText(signups.map((s) => s.email).join("\n"));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard blocked (e.g. insecure context) — nothing to do.
    }
  };

  return (
    <>
      <div className="mb-4 flex items-center justify-between gap-2">
        <span className="text-sm text-muted-foreground">
          {signups.length} {signups.length === 1 ? "signup" : "signups"}
        </span>
        <Button
          size="sm"
          variant="outline"
          onClick={copyEmails}
          disabled={signups.length === 0}
        >
          {copied ? <Check className="size-4" /> : <Copy className="size-4" />}
          {copied ? "Copied" : "Copy all emails"}
        </Button>
      </div>

      {signups.length === 0 ? (
        <p className="py-8 text-center text-sm text-muted-foreground">
          No signups yet.
        </p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Email</TableHead>
              <TableHead>Signed up</TableHead>
              <TableHead>Country</TableHead>
              <TableHead>IP</TableHead>
              <TableHead>User agent</TableHead>
              <TableHead className="w-[80px] text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {signups.map((s) => (
              <TableRow key={s.id}>
                <TableCell className="font-medium">{s.email}</TableCell>
                <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
                  {formatDate(s.createdAt)}
                </TableCell>
                <TableCell className="text-xs text-muted-foreground">
                  {s.country ?? "—"}
                </TableCell>
                <TableCell className="text-xs text-muted-foreground">
                  {s.ip ?? "—"}
                </TableCell>
                <TableCell
                  className="max-w-[260px] truncate text-xs text-muted-foreground"
                  title={s.userAgent ?? undefined}
                >
                  {s.userAgent ?? "—"}
                </TableCell>
                <TableCell className="text-right">
                  <Button
                    size="sm"
                    variant="outline"
                    aria-label={`Delete ${s.email}`}
                    disabled={del.isPending}
                    onClick={() => {
                      if (window.confirm(`Delete ${s.email} from the beta list?`)) {
                        del.mutate({ id: s.id });
                      }
                    }}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
