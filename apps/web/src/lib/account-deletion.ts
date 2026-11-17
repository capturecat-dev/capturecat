/**
 * Account deletion — the copy and the response mapping shared by the
 * settings page's "Delete account" section (components/dashboard/
 * delete-account-section.tsx) and the tRPC relay (lib/trpc/routers/account.ts).
 *
 * The API is DELETE /api/me (apps/api). The same copy is shown by the iOS and
 * Mac apps, so keep the three in step.
 *
 * Pure on purpose (no server or React imports): account-deletion.test.ts
 * pins every status the API can answer to the state the page shows.
 */

export const DELETE_ACCOUNT_TITLE = "Delete account";

export const DELETE_ACCOUNT_BODY =
  "This permanently deletes your CaptureCat account and everything in it: shared videos and their links, " +
  "cloud projects and their history, comments you've written, connected devices and agent connections. " +
  "An active subscription is cancelled immediately, with no further charges. If you connected your own " +
  "storage bucket, we forget its keys but never delete the files in your bucket. This can't be undone.";

/** What the user types to arm the destructive button. */
export const DELETE_CONFIRMATION_WORD = "DELETE";

export const DELETED_TOAST = "Your account was deleted.";

export const NETWORK_FAILURE_MESSAGE =
  "We couldn't reach CaptureCat, so nothing was deleted. Check your connection and try again.";

const GENERIC_FAILURE_MESSAGE = "Something went wrong, so nothing was deleted. Try again in a moment.";
const BILLING_FAILURE_MESSAGE =
  "We couldn't cancel your subscription, so nothing was deleted. Try again in a moment.";
const BLOCKED_MESSAGE =
  "This account is blocked, so it can't be deleted here. Email contact@capturecat.so and we'll help.";

/** Whether the typed confirmation arms the button (exact word, surrounding spaces ignored). */
export function confirmationMatches(typed: string): boolean {
  return typed.trim() === DELETE_CONFIRMATION_WORD;
}

export type DeleteAccountOutcome =
  /** Deleted now (or already: a 401 after a lost response means the session is gone). */
  | { kind: "deleted"; cancelledSubscriptions: number; cleanup: "pending" | "done" }
  /** Owns a team that still has other members — handled on the Team page. */
  | { kind: "team"; message: string; teamName: string | null }
  /** Stripe could not be reached; nothing was deleted. */
  | { kind: "billing"; message: string }
  | { kind: "blocked"; message: string }
  | { kind: "error"; message: string };

type ApiBody = {
  error?: unknown;
  code?: unknown;
  deleted?: unknown;
  cancelledSubscriptions?: unknown;
  cleanup?: unknown;
  team?: { name?: unknown } | null;
};

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

/** Maps DELETE /api/me's status + JSON body to what the page shows. */
export function deleteAccountOutcome(status: number, body: unknown): DeleteAccountOutcome {
  const b = (body && typeof body === "object" ? body : {}) as ApiBody;
  if (status >= 200 && status < 300) {
    return {
      kind: "deleted",
      cancelledSubscriptions: typeof b.cancelledSubscriptions === "number" ? b.cancelledSubscriptions : 0,
      cleanup: b.cleanup === "done" ? "done" : "pending",
    };
  }
  // The session is gone: a retry after the first response was lost, or the
  // account was already deleted elsewhere. Either way the right move is to
  // sign out locally.
  if (status === 401) {
    return { kind: "deleted", cancelledSubscriptions: 0, cleanup: "pending" };
  }
  if (status === 409 || b.code === "team_has_members") {
    return {
      kind: "team",
      message:
        text(b.error) ??
        "You own a team that still has other members. Make another member an owner, or remove them, on the Team page first.",
      teamName: text(b.team?.name),
    };
  }
  if (b.code === "billing_unavailable" || status === 502) {
    return { kind: "billing", message: text(b.error) ?? BILLING_FAILURE_MESSAGE };
  }
  if (status === 403 && text(b.error)?.toLowerCase().includes("blocked")) {
    return { kind: "blocked", message: BLOCKED_MESSAGE };
  }
  return { kind: "error", message: text(b.error) ?? GENERIC_FAILURE_MESSAGE };
}
