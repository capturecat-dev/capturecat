import { useState } from "react";
import { toast } from "sonner";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { trpc } from "@/lib/trpc/client";

const SOURCE_LABEL = { grant: "Assigned here", stripe: "Pays via Stripe", none: "Free" } as const;

const day = (iso: string) => new Date(iso).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });

/**
 * "Assign plan" for one user. An assigned plan is a complimentary Stripe
 * subscription (100% off, forever, optional end date) — the API route
 * explains why — so it counts as paid everywhere. A customer who PAYS is
 * shown but never changed from here: that lives in Stripe.
 */
export function UserPlanSection({ userId, email }: { userId: string; email: string }) {
  const utils = trpc.useUtils();
  const { data, isLoading, error } = trpc.admin.userPlan.useQuery({ userId });
  const [choice, setChoice] = useState<string | null>(null);
  const [until, setUntil] = useState("");
  const [confirm, setConfirm] = useState<"assign" | "remove" | null>(null);

  const assign = trpc.admin.assignPlan.useMutation({
    onSuccess: (res) => {
      toast.success(res.plan === "free" ? `${email} is back on Free` : `${email} is on ${planLabel(res.plan)}`);
      setChoice(null);
      setUntil("");
      void utils.admin.userPlan.invalidate({ userId });
      void utils.admin.listUsers.invalidate();
      void utils.admin.userActivity.invalidate({ userId });
    },
    onError: (e) => toast.error(e.message),
  });

  if (isLoading) return <Spinner />;
  if (error || !data) return <p className="text-sm text-destructive">{error?.message ?? "Could not load the plan"}</p>;

  const assignable = data.plans.filter((p) => p.name !== "free");
  function planLabel(name: string) {
    return data?.plans.find((p) => p.name === name)?.displayName ?? name;
  }
  const selected = choice ?? (data.source === "grant" ? data.plan : null);
  const today = new Date().toISOString().slice(0, 10);
  const changed = selected !== null && (selected !== data.plan || until !== "" || data.source !== "grant");

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-base font-medium">{data.plan === "free" ? "Free" : planLabel(data.plan)}</span>
        <Badge variant={data.source === "grant" ? "default" : data.source === "stripe" ? "secondary" : "outline"}>
          {SOURCE_LABEL[data.source]}
        </Badge>
        {data.status && data.status !== "active" && <Badge variant="outline">{data.status}</Badge>}
      </div>
      {data.grant && (
        <p className="text-xs text-muted-foreground">
          Assigned by {data.grant.grantedBy} on {day(data.grant.grantedAt)}
          {data.grant.until ? ` · ends ${day(data.grant.until)}` : " · no end date"}
        </p>
      )}

      {data.source === "stripe" ? (
        <p className="text-sm text-muted-foreground">
          This user pays through Stripe. Change or cancel their subscription in Stripe — assigning a plan here never
          touches what a customer pays for.
        </p>
      ) : (
        <div className="flex flex-wrap items-end gap-2">
          <div className="flex flex-col gap-1">
            <span className="text-xs text-muted-foreground">Plan</span>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="min-w-40 justify-between">
                  {selected ? planLabel(selected) : "Choose a plan"}
                  <span aria-hidden className="text-muted-foreground">▾</span>
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start">
                <DropdownMenuLabel>Assign plan</DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuRadioGroup value={selected ?? ""} onValueChange={setChoice}>
                  {assignable.map((p) => (
                    <DropdownMenuRadioItem key={p.name} value={p.name}>
                      {p.displayName}
                      {!p.isActive && <span className="ml-2 text-xs text-muted-foreground">hidden</span>}
                    </DropdownMenuRadioItem>
                  ))}
                </DropdownMenuRadioGroup>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
          <label className="flex flex-col gap-1">
            <span className="text-xs text-muted-foreground">Until (optional)</span>
            <Input type="date" min={today} value={until} onChange={(e) => setUntil(e.target.value)} className="h-8 w-40" />
          </label>
          <Button size="sm" disabled={!changed || assign.isPending} onClick={() => setConfirm("assign")}>
            {assign.isPending && confirm !== "remove" ? <Spinner /> : null}
            {data.source === "grant" ? "Change plan" : "Assign plan"}
          </Button>
          {data.source === "grant" && (
            <Button size="sm" variant="ghost" disabled={assign.isPending} onClick={() => setConfirm("remove")}>
              Remove
            </Button>
          )}
        </div>
      )}

      <AlertDialog open={confirm !== null} onOpenChange={(open) => !open && setConfirm(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {confirm === "remove" ? `Move ${email} back to Free?` : `Give ${email} ${selected ? planLabel(selected) : ""}?`}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {confirm === "remove"
                ? "Their complimentary subscription is cancelled in Stripe now, and they lose the plan's features straight away."
                : `A complimentary subscription (100% off) is created in Stripe — they are never charged. ${
                    until ? `It ends on ${day(`${until}T12:00:00Z`)}.` : "It has no end date."
                  }${data.source === "grant" ? " Their current assigned plan is replaced." : ""}`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              variant={confirm === "remove" ? "destructive" : "default"}
              onClick={() =>
                assign.mutate({
                  userId,
                  plan: confirm === "remove" ? "free" : (selected ?? "free"),
                  until: confirm === "remove" || !until ? null : until,
                })
              }
            >
              {confirm === "remove" ? "Move to Free" : "Assign"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
