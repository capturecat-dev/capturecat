import { useState } from "react";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import {
  WEBHOOK_EVENTS,
  WEBHOOK_EVENT_LABELS,
  relativeTime,
  webhookUrlProblem,
  type WebhookDelivery,
  type WebhookEndpointSummary,
  type WebhookEvent,
} from "@/lib/agent-access";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { EmptyNote, Field, Row, Section } from "@/components/dashboard/studio";
import { CopyBlock } from "@/components/dashboard/agent-access-card";
import { PlanUnavailableNote } from "@/components/dashboard/plan-unavailable-note";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import { cn } from "@/lib/utils";

/**
 * Webhooks: signed POSTs to the user's own endpoints when something happens
 * on their account (apps/api/src/lib/webhooks.ts), so an agent can react
 * instead of polling. One Section of Settings' single surface, under Agent
 * access: add an endpoint (URL + events) → its secret shown ONCE → the list
 * with on/off, "Send test", recent deliveries and delete. The API decides
 * everything (SSRF guard, plan gate, caps); this only asks.
 */
export function WebhooksCard() {
  const utils = trpc.useUtils();
  const { data, isLoading } = trpc.webhooks.list.useQuery();
  const [adding, setAdding] = useState(false);
  const [created, setCreated] = useState<{
    secret: string;
    url: string;
  } | null>(null);
  const create = trpc.webhooks.create.useMutation({
    onSuccess: (r) => {
      setCreated({ secret: r.secret, url: r.endpoint.url });
      setAdding(false);
      void utils.webhooks.list.invalidate();
    },
    onError: (e) => toast.error(e.message),
  });

  const endpoints = data?.endpoints ?? [];
  const available = data?.available ?? true;
  const atLimit = data ? endpoints.length >= data.maxEndpoints : false;

  return (
    <Section
      icon={<CCIcon name="bell" />}
      title="Webhooks"
      description={
        <>
          CaptureCat POSTs a signed event to your endpoint when a video is
          ready, someone comments or views a share, a project is saved or an
          upload fails — signed the{" "}
          <a
            className="underline underline-offset-4"
            href="https://www.standardwebhooks.com"
            target="_blank"
            rel="noreferrer"
          >
            Standard Webhooks
          </a>{" "}
          way. Agents with the webhooks scope can add endpoints too.
        </>
      }
      actions={
        available && !adding && !created && endpoints.length > 0 ? (
          <Button
            size="sm"
            variant="outline"
            disabled={atLimit}
            onClick={() => setAdding(true)}
          >
            <CCIcon name="plus" data-icon="inline-start" />
            Add endpoint
          </Button>
        ) : null
      }
    >
      <div className="space-y-3">
        {!available && (
          <PlanUnavailableNote>
            Webhooks aren't part of your plan. Existing endpoints stay listed so
            you can switch them off or delete them.
          </PlanUnavailableNote>
        )}

        {created && (
          <SecretReveal {...created} onDone={() => setCreated(null)} />
        )}
        {adding && (
          <AddEndpointForm
            pending={create.isPending}
            onCancel={() => setAdding(false)}
            onSubmit={(v) => create.mutate(v)}
          />
        )}

        {isLoading ? (
          <Skeleton className="h-[62px] w-full rounded-[0.875rem]" />
        ) : endpoints.length === 0 ? (
          available &&
          !adding &&
          !created && (
            <EmptyNote className="flex-col gap-3">
              <span>
                No endpoints yet. Add one to get events as they happen.
              </span>
              <Button size="sm" onClick={() => setAdding(true)}>
                <CCIcon name="plus" data-icon="inline-start" />
                Add endpoint
              </Button>
            </EmptyNote>
          )
        ) : (
          <div className="space-y-2">
            {endpoints.map((ep, i) => (
              <EndpointRow
                key={ep.id}
                endpoint={ep}
                index={i}
                available={available}
              />
            ))}
            {atLimit && (
              <p className="text-xs text-muted-foreground">
                That's the most endpoints allowed. Delete one to add another.
              </p>
            )}
          </div>
        )}
      </div>
    </Section>
  );
}

/* ------------------------------------------------------------------ */

function EventChip({
  event,
  checked,
  onToggle,
}: {
  event: WebhookEvent;
  checked: boolean;
  onToggle: () => void;
}) {
  const info = WEBHOOK_EVENT_LABELS[event];
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={checked}
      onClick={onToggle}
      className={cn(
        "flex min-w-0 items-start gap-2.5 rounded-[0.875rem] px-3 py-2.5 text-left transition-[color,background-color,box-shadow] duration-200",
        checked
          ? "cc-chip-on"
          : "cc-well text-muted-foreground hover:text-foreground",
      )}
    >
      <span
        aria-hidden
        className={cn(
          "mt-0.5 grid size-4 shrink-0 place-items-center rounded-[5px] transition-colors duration-200",
          checked ? "bg-primary text-primary-foreground" : "cc-float-chip",
        )}
      >
        {checked && <CCIcon name="check" size={12} weight="semibold" />}
      </span>
      <span className="min-w-0">
        <span className="flex items-center gap-1.5 text-sm font-medium text-foreground">
          {info.label}
          <code className="text-[10.5px] font-normal text-muted-foreground">
            {event}
          </code>
        </span>
        <span className="mt-0.5 block text-xs leading-snug text-muted-foreground">
          {info.description}
        </span>
      </span>
    </button>
  );
}

function AddEndpointForm({
  pending,
  onCancel,
  onSubmit,
}: {
  pending: boolean;
  onCancel: () => void;
  onSubmit: (v: {
    url: string;
    events: WebhookEvent[];
    description?: string;
  }) => void;
}) {
  const [url, setUrl] = useState("");
  const [description, setDescription] = useState("");
  const [events, setEvents] = useState<WebhookEvent[]>([
    "video.ready",
    "comment.created",
  ]);
  const problem = url.trim() ? webhookUrlProblem(url) : null;
  const ready = url.trim().length > 0 && !problem && events.length > 0;
  const toggle = (e: WebhookEvent) =>
    setEvents((cur) =>
      cur.includes(e) ? cur.filter((x) => x !== e) : [...cur, e],
    );

  return (
    <form
      className="studio-well dsh-rise space-y-4 p-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready)
          onSubmit({
            url: url.trim(),
            events,
            ...(description.trim() ? { description: description.trim() } : {}),
          });
      }}
    >
      <Field
        label="Endpoint URL"
        error={problem}
        hint="Public https only. Redirects are not followed."
      >
        <input
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="https://example.com/hooks/capturecat"
          className="studio-input w-full"
          inputMode="url"
          autoFocus
          autoComplete="off"
        />
      </Field>
      <Field label="Label (optional)">
        <input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="My agent"
          maxLength={100}
          className="studio-input w-full"
          autoComplete="off"
        />
      </Field>
      <div className="space-y-2">
        <span className="studio-eyebrow block">Events</span>
        <div className="grid gap-2 sm:grid-cols-2">
          {WEBHOOK_EVENTS.map((e) => (
            <EventChip
              key={e}
              event={e}
              checked={events.includes(e)}
              onToggle={() => toggle(e)}
            />
          ))}
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" disabled={!ready || pending}>
          {pending ? (
            <>
              <Spinner data-icon="inline-start" />
              Adding…
            </>
          ) : (
            "Add endpoint"
          )}
        </Button>
        <Button
          type="button"
          variant="ghost"
          onClick={onCancel}
          disabled={pending}
        >
          Cancel
        </Button>
        {events.length === 0 && (
          <span className="text-xs text-muted-foreground">
            Pick at least one event.
          </span>
        )}
      </div>
    </form>
  );
}

function SecretReveal({
  secret,
  url,
  onDone,
}: {
  secret: string;
  url: string;
  onDone: () => void;
}) {
  return (
    <div className="studio-well dsh-rise space-y-4 p-4">
      <div className="flex items-start gap-2.5">
        <CCIcon
          name="seal-check"
          className="mt-0.5 size-4 shrink-0 text-cc-green-text"
        />
        <div className="min-w-0">
          <p className="truncate text-sm font-medium">Sending to {url}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">
            Copy the signing secret now: it's shown only this once. Verify each
            delivery's{" "}
            <code className="text-foreground/80">webhook-signature</code> with
            it.
          </p>
        </div>
      </div>
      <CopyBlock label="Signing secret" value={secret} />
      <div className="flex justify-end">
        <Button size="sm" onClick={onDone}>
          Done
        </Button>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */

function EndpointRow({
  endpoint: ep,
  index,
  available,
}: {
  endpoint: WebhookEndpointSummary;
  index: number;
  available: boolean;
}) {
  const utils = trpc.useUtils();
  const [open, setOpen] = useState(false);
  const refresh = () => {
    void utils.webhooks.list.invalidate();
    void utils.webhooks.deliveries.invalidate({ id: ep.id });
  };
  const update = trpc.webhooks.update.useMutation({
    onSuccess: refresh,
    onError: (e) => toast.error(e.message),
  });
  const remove = trpc.webhooks.remove.useMutation({
    onSuccess: () => {
      refresh();
      toast.success("Endpoint deleted");
    },
    onError: (e) => toast.error(e.message),
  });
  const test = trpc.webhooks.test.useMutation({
    onSuccess: (r) => {
      setOpen(true);
      refresh();
      if (r.delivery.status === "delivered")
        toast.success(`Test delivered (HTTP ${r.delivery.responseCode})`);
      else toast.error(`Test failed: ${r.delivery.error ?? "no response"}`);
    },
    onError: (e) => toast.error(e.message),
  });
  const health = ep.disabledReason
    ? ep.disabledReason
    : ep.failureCount > 0
      ? `${ep.failureCount} failed deliver${ep.failureCount === 1 ? "y" : "ies"} in a row`
      : ep.lastSuccessAt
        ? `last delivered ${relativeTime(ep.lastSuccessAt)}`
        : "nothing delivered yet";

  return (
    <Row className={cn("dsh-rise", !ep.active && "opacity-75")} index={index}>
      {/* One full-width column: .studio-row is an unlayered flex row that
          centres its children, which Tailwind utilities can't override. */}
      <div className="min-w-0 flex-1 space-y-3">
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="flex min-w-0 items-start gap-2.5">
            <span
              aria-hidden
              className={cn(
                "mt-1.5 size-1.5 shrink-0 rounded-full",
                !ep.active
                  ? "bg-muted-foreground/40"
                  : ep.failureCount > 0
                    ? "bg-cc-amber"
                    : "bg-cc-green",
              )}
            />
            <div className="min-w-0">
              <p className="truncate text-sm font-medium" title={ep.url}>
                {ep.description ?? ep.url}
              </p>
              {ep.description && (
                <p className="truncate text-xs text-muted-foreground">
                  {ep.url}
                </p>
              )}
              <div className="mt-1 flex flex-wrap gap-1">
                {ep.events.map((e) => (
                  <span
                    key={e}
                    className="cc-well inline-flex h-5 items-center rounded-full px-2 font-mono text-[10.5px] text-muted-foreground"
                  >
                    {e}
                  </span>
                ))}
              </div>
              <p
                className={cn(
                  "mt-1 text-xs",
                  ep.disabledReason || ep.failureCount > 0
                    ? "text-cc-amber-text"
                    : "text-muted-foreground",
                )}
              >
                {ep.createdBy === "agent" ? "Added by an agent · " : ""}
                {health}
              </p>
            </div>
          </div>
          <Switch
            checked={ep.active}
            disabled={update.isPending || (!ep.active && !available)}
            aria-label={ep.active ? "Switch off" : "Switch on"}
            onCheckedChange={(active) => update.mutate({ id: ep.id, active })}
          />
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          <Button
            variant="outline"
            size="sm"
            disabled={!available || test.isPending}
            onClick={() => test.mutate({ id: ep.id })}
          >
            {test.isPending ? (
              <Spinner data-icon="inline-start" />
            ) : (
              <CCIcon name="share" data-icon="inline-start" />
            )}
            Send test
          </Button>
          <Button
            variant="ghost"
            size="sm"
            aria-expanded={open}
            onClick={() => setOpen((v) => !v)}
          >
            <CCIcon
              name={open ? "chevron-down" : "chevron-right"}
              data-icon="inline-start"
            />
            Recent deliveries
          </Button>
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button
                variant="ghost"
                size="sm"
                className="ml-auto text-destructive hover:text-destructive"
                disabled={remove.isPending}
              >
                {remove.isPending ? (
                  <Spinner data-icon="inline-start" />
                ) : (
                  <CCIcon name="trash" data-icon="inline-start" />
                )}
                Delete
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Delete this endpoint?</AlertDialogTitle>
                <AlertDialogDescription>
                  CaptureCat stops sending events to {ep.url} and forgets its
                  delivery history. Anything still waiting to be retried is
                  dropped.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Keep it</AlertDialogCancel>
                <AlertDialogAction
                  variant="destructive"
                  onClick={() => remove.mutate({ id: ep.id })}
                >
                  Delete
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>

        {open && <Deliveries id={ep.id} />}
      </div>
    </Row>
  );
}

function Deliveries({ id }: { id: string }) {
  const { data, isLoading } = trpc.webhooks.deliveries.useQuery({ id });
  if (isLoading) return <Skeleton className="h-16 w-full rounded-[0.75rem]" />;
  const rows = data?.deliveries ?? [];
  if (rows.length === 0)
    return <p className="text-xs text-muted-foreground">No deliveries yet.</p>;
  return (
    <ul className="divide-y divide-border">
      {rows.map((d) => (
        <li
          key={d.id}
          className="flex min-w-0 items-start gap-2.5 py-2 first:pt-0 last:pb-0"
        >
          <span
            aria-hidden
            className={cn("mt-1.5 size-1.5 shrink-0 rounded-full", dot(d))}
          />
          <div className="min-w-0 flex-1">
            <div className="flex min-w-0 flex-wrap items-baseline gap-x-2 text-[13px]">
              <code className="text-foreground/90">{d.event}</code>
              <span className="text-xs text-muted-foreground">
                {statusText(d)} · {relativeTime(d.createdAt)}
              </span>
            </div>
            {d.error && d.status !== "delivered" && (
              <p className="mt-0.5 truncate text-xs text-cc-amber-text">
                {d.error}
              </p>
            )}
          </div>
        </li>
      ))}
    </ul>
  );
}

function dot(d: WebhookDelivery): string {
  if (d.status === "delivered") return "bg-cc-green";
  if (d.status === "pending") return "bg-cc-amber";
  return "bg-muted-foreground/40";
}

function statusText(d: WebhookDelivery): string {
  switch (d.status) {
    case "delivered":
      return `delivered${d.responseCode ? ` (HTTP ${d.responseCode})` : ""}${d.attempt > 1 ? ` on try ${d.attempt}` : ""}`;
    case "pending":
      return d.nextAttemptAt
        ? `retrying in ${Math.max(1, Math.ceil((Date.parse(d.nextAttemptAt) - Date.now()) / 60_000))} min (try ${d.attempt + 1})`
        : "sending";
    case "failed":
      return `gave up after ${d.attempt} tries`;
    case "cancelled":
      return "cancelled";
  }
}
