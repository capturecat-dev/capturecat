import { apiFetch } from "@/lib/session";
import { deleteAccountOutcome, NETWORK_FAILURE_MESSAGE, type DeleteAccountOutcome } from "@/lib/account-deletion";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * The signed-in user's own account — api.capturecat.so DELETE /api/me
 * (apps/api). apiFetch forwards the session cookie and sends the trusted
 * Origin the API's cookie-CSRF check requires.
 *
 * Expected refusals (a team with other members, Stripe unreachable) come back
 * as an outcome rather than a thrown error, so the page can show the API's own
 * words and the right next step.
 */
export const accountRouter = createTRPCRouter({
  delete: authedProcedure.mutation(async (): Promise<DeleteAccountOutcome> => {
    let res: Response;
    try {
      res = await apiFetch("/api/me", { method: "DELETE" });
    } catch (err) {
      console.error("account: delete request failed", (err as Error).message);
      return { kind: "error", message: NETWORK_FAILURE_MESSAGE };
    }
    const body = await res.json().catch(() => null);
    return deleteAccountOutcome(res.status, body);
  }),
});
