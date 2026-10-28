import { useMemo, useState } from "react";
import { ShieldAlert } from "lucide-react";

import { Badge } from "@/components/ui/badge";
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
import { UserActivitySheet } from "@/components/admin/user-activity-sheet";
import type { SignupSource, UserUsage } from "@/lib/analytics-types";
import { countryLabel, formatBytes, formatNumber, relativeTime } from "@/lib/format";
import { cn } from "@/lib/utils";

type Tier = "free" | "tester" | "paid" | "blocked";

type AdminUser = {
  id: string;
  email: string;
  name: string | null;
  createdAt: string;
  tester: boolean;
  blocked: boolean;
  role: string;
  paid: boolean;
  tier: Tier;
  providers: string[];
  signup: SignupSource;
  usage: UserUsage | null;
};

type Sort = "newest" | "storage" | "active";
const SORTS: Array<{ id: Sort; label: string }> = [
  { id: "newest", label: "Newest" },
  { id: "storage", label: "Most storage" },
  { id: "active", label: "Recently active" },
];

const sorters: Record<Sort, (a: AdminUser, b: AdminUser) => number> = {
  newest: (a, b) => b.createdAt.localeCompare(a.createdAt),
  storage: (a, b) => (b.usage?.storageBytes ?? 0) - (a.usage?.storageBytes ?? 0),
  active: (a, b) => (b.usage?.lastActive ?? "").localeCompare(a.usage?.lastActive ?? ""),
};

function badgeVariant(tier: Tier): "default" | "secondary" | "destructive" | "outline" {
  switch (tier) {
    case "paid":
      return "default";
    case "tester":
      return "secondary";
    case "blocked":
      return "destructive";
    default:
      return "outline";
  }
}

const TIER_LABEL: Record<Tier, string> = {
  free: "Free",
  tester: "Tester",
  paid: "Paid",
  blocked: "Blocked",
};

export function UsersTable() {
  const { data, isLoading } = trpc.admin.listUsers.useQuery();
  const utils = trpc.useUtils();
  const setEntitlement = trpc.admin.setEntitlement.useMutation({
    onSuccess: () => utils.admin.listUsers.invalidate(),
  });

  const [sort, setSort] = useState<Sort>("newest");
  const [openUser, setOpenUser] = useState<string | null>(null);
  const users = useMemo(() => [...(data?.users ?? [])].sort(sorters[sort]), [data, sort]);

  if (isLoading) return <TableLoading />;

  return (
    <>
      {/*
        `paid` is shown but not settable. It is derived from a live Stripe
        subscription, and @better-auth/stripe writes that table only from its
        webhook — a locally granted flag would be a paid state Stripe never
        agrees with. Comp with a plan freeTrial or a 100%-off coupon; `tester`
        already ranks between free and paid for everything else.
      */}
      <div className="mb-4 flex items-start gap-2 rounded-md border p-3 text-xs text-muted-foreground">
        <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
        <span>
          Paid status comes from Stripe and cannot be set here. Grant
          <strong> Tester</strong> for comped access, or add a free trial /
          100%-off coupon in Stripe.
        </span>
      </div>

      <div className="mb-3 flex items-center justify-between gap-4">
        <span className="text-xs text-muted-foreground">
          {formatNumber(users.length)} users · click one for what they store and do
        </span>
        <div className="inline-flex rounded-lg border p-0.5" role="radiogroup" aria-label="Sort users">
          {SORTS.map((s) => (
            <button
              key={s.id}
              type="button"
              role="radio"
              aria-checked={sort === s.id}
              onClick={() => setSort(s.id)}
              className={cn(
                "rounded-md px-3 py-1 text-xs transition-colors",
                sort === s.id ? "bg-secondary text-secondary-foreground" : "text-muted-foreground hover:text-foreground",
              )}
            >
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Email</TableHead>
            <TableHead>Name</TableHead>
            <TableHead>Tier</TableHead>
            <TableHead>From</TableHead>
            <TableHead className="text-right">Stored</TableHead>
            <TableHead>Activity</TableHead>
            <TableHead>Created</TableHead>
            <TableHead className="w-[260px]">Update</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {users.map((user) => (
            <UserRow
              key={user.id}
              user={user}
              isPending={setEntitlement.isPending}
              onOpen={() => setOpenUser(user.id)}
              onSave={(tester, blocked) =>
                setEntitlement.mutate({ userId: user.id, tester, blocked })
              }
            />
          ))}
        </TableBody>
      </Table>
      <UserActivitySheet userId={openUser} onClose={() => setOpenUser(null)} />
    </>
  );
}

/** "ChatGPT", "Mac app", or "—" for accounts made before tracking. */
function sourceLabel(s: SignupSource): string {
  if (!s.via) return "—";
  if (s.source && s.source.id !== "direct") return s.source.label;
  return s.via === "desktop" ? "Mac app" : "Direct";
}

function UserRow({
  user,
  onSave,
  onOpen,
  isPending,
}: {
  user: AdminUser;
  onSave: (tester: boolean, blocked: boolean) => void;
  onOpen: () => void;
  isPending: boolean;
}) {
  const u = user.usage;
  return (
    <TableRow>
      <TableCell className="font-medium">
        <button type="button" onClick={onOpen} className="flex flex-col text-left hover:underline">
          <span>{user.email}</span>
          <span className="text-xs font-normal text-muted-foreground">{user.id}</span>
        </button>
      </TableCell>
      <TableCell>{user.name ?? "—"}</TableCell>
      <TableCell>
        <div className="flex items-center gap-1.5">
          <Badge variant={badgeVariant(user.tier)}>{TIER_LABEL[user.tier]}</Badge>
          {user.role !== "user" && <Badge variant="outline">{user.role}</Badge>}
        </div>
      </TableCell>
      <TableCell className="text-xs">
        <div className="flex flex-col">
          <span>{sourceLabel(user.signup)}</span>
          {user.signup.country && (
            <span className="text-muted-foreground">{countryLabel(user.signup.country)}</span>
          )}
        </div>
      </TableCell>
      <TableCell className="text-right text-xs tabular-nums">
        {u && u.storageBytes > 0 ? formatBytes(u.storageBytes) : <span className="text-muted-foreground">—</span>}
      </TableCell>
      <TableCell className="text-xs">
        <div className="flex flex-col">
          <span>{u ? relativeTime(u.lastActive) : "never"}</span>
          {u && (u.videos > 0 || u.projects > 0) && (
            <span className="text-muted-foreground">
              {[
                u.videos > 0 && `${formatNumber(u.videos)} shared`,
                u.projects > 0 && `${formatNumber(u.projects)} projects`,
              ].filter(Boolean).join(" · ")}
            </span>
          )}
        </div>
      </TableCell>
      <TableCell className="text-xs text-muted-foreground" title={user.createdAt}>
        {relativeTime(user.createdAt)}
      </TableCell>
      <TableCell>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant={user.tester ? "secondary" : "outline"}
            disabled={isPending}
            onClick={() => onSave(!user.tester, user.blocked)}
          >
            {user.tester ? "Revoke tester" : "Make tester"}
          </Button>
          <Button
            size="sm"
            variant={user.blocked ? "destructive" : "outline"}
            disabled={isPending}
            onClick={() => onSave(user.tester, !user.blocked)}
          >
            {user.blocked ? "Unblock" : "Block"}
          </Button>
        </div>
      </TableCell>
    </TableRow>
  );
}
