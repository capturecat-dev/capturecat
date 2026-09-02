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

  if (isLoading) return <TableLoading />;
  const users = data?.users ?? [];

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

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Email</TableHead>
            <TableHead>Name</TableHead>
            <TableHead>Tier</TableHead>
            <TableHead>Role</TableHead>
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
              onSave={(tester, blocked) =>
                setEntitlement.mutate({ userId: user.id, tester, blocked })
              }
            />
          ))}
        </TableBody>
      </Table>
    </>
  );
}

function UserRow({
  user,
  onSave,
  isPending,
}: {
  user: AdminUser;
  onSave: (tester: boolean, blocked: boolean) => void;
  isPending: boolean;
}) {
  return (
    <TableRow>
      <TableCell className="font-medium">
        <div className="flex flex-col">
          <span>{user.email}</span>
          <span className="text-xs text-muted-foreground">{user.id}</span>
        </div>
      </TableCell>
      <TableCell>{user.name ?? "—"}</TableCell>
      <TableCell>
        <Badge variant={badgeVariant(user.tier)}>{TIER_LABEL[user.tier]}</Badge>
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">{user.role}</TableCell>
      <TableCell className="text-xs text-muted-foreground">{user.createdAt}</TableCell>
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
