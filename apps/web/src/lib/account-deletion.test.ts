import { describe, expect, it } from "vitest";

import {
  confirmationMatches,
  DELETE_ACCOUNT_BODY,
  deleteAccountOutcome,
} from "./account-deletion";

describe("DELETE /api/me → what the settings page shows", () => {
  it("200 is deleted, with the counts the API reports", () => {
    expect(
      deleteAccountOutcome(200, { deleted: true, jobId: "j1", cancelledSubscriptions: 1, cleanup: "done" }),
    ).toEqual({ kind: "deleted", cancelledSubscriptions: 1, cleanup: "done" });
    expect(deleteAccountOutcome(200, { deleted: true })).toEqual({
      kind: "deleted",
      cancelledSubscriptions: 0,
      cleanup: "pending",
    });
  });

  it("401 means the session is already gone — sign out as if deleted", () => {
    expect(deleteAccountOutcome(401, { error: "Invalid or expired session" }).kind).toBe("deleted");
    expect(deleteAccountOutcome(401, null).kind).toBe("deleted");
  });

  it("409 shows the server's words and names the team", () => {
    const msg = "You own the team “Acme” with 2 other members. Make another member an owner first.";
    expect(
      deleteAccountOutcome(409, {
        error: msg,
        code: "team_has_members",
        team: { id: "o1", name: "Acme", otherMembers: 2 },
      }),
    ).toEqual({ kind: "team", message: msg, teamName: "Acme" });
    expect(deleteAccountOutcome(409, {})).toMatchObject({ kind: "team", teamName: null });
  });

  it("502 billing: nothing was deleted", () => {
    const out = deleteAccountOutcome(502, {
      error: "We couldn't cancel your subscription, so nothing was deleted. Try again in a moment.",
      code: "billing_unavailable",
    });
    expect(out).toEqual({
      kind: "billing",
      message: "We couldn't cancel your subscription, so nothing was deleted. Try again in a moment.",
    });
    expect(deleteAccountOutcome(502, "not json").kind).toBe("billing");
  });

  it("403 blocked and anything else are errors that say nothing was deleted", () => {
    expect(deleteAccountOutcome(403, { error: "Account blocked" }).kind).toBe("blocked");
    expect(deleteAccountOutcome(403, { error: "Origin not allowed" })).toEqual({
      kind: "error",
      message: "Origin not allowed",
    });
    expect(deleteAccountOutcome(500, null)).toEqual({
      kind: "error",
      message: "Something went wrong, so nothing was deleted. Try again in a moment.",
    });
  });
});

describe("confirmation", () => {
  it("arms only on the exact word", () => {
    expect(confirmationMatches("DELETE")).toBe(true);
    expect(confirmationMatches("  DELETE ")).toBe(true);
    expect(confirmationMatches("delete")).toBe(false);
    expect(confirmationMatches("DELET")).toBe(false);
    expect(confirmationMatches("")).toBe(false);
  });

  it("the copy says what is deleted, that billing stops, and that the customer's bucket is untouched", () => {
    for (const phrase of [
      "shared videos",
      "cloud projects",
      "comments you've written",
      "connected devices",
      "agent connections",
      "subscription is cancelled immediately",
      "never delete the files in your bucket",
      "can't be undone",
    ]) {
      expect(DELETE_ACCOUNT_BODY).toContain(phrase);
    }
  });
});
