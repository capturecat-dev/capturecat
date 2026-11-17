# Account deletion — deploy notes

`DELETE /api/me` deletes a CaptureCat account and everything it owns. It is
what App Store Guideline 5.1.1(v) asks for: the iOS app has Account → Delete
Account, and the web dashboard has Settings → Delete account. Until now,
deleting an account meant emailing contact@capturecat.so.

How it works and what happens to every table and bucket is described in
`apps/api/README.md` → "Account deletion (`DELETE /api/me`)". This page covers
getting it live.

## What ships where

| Piece | Where | How it reaches production |
| --- | --- | --- |
| API (route, lib, migration 0043, tests, README) | `apps/api` | **`docs/account-deletion-api.patch`**, applied to the main checkout's working tree (see below) |
| Web Settings section | `apps/web` | merge of this branch, then the usual web deploy |
| iOS Delete Account + gate | `apps/ios` | merge of this branch, then the next TestFlight / App Store build |
| Mac | — | nothing (see "Mac" below) |

## Why a patch for the API

Production was deployed from the main checkout's **working tree**, which
holds uncommitted API work this branch (based on `studio-phase1`) does not
have: `migrations/0041_ai_search.sql`, `src/lib/ai-search/`,
`src/routes/admin-ai-search.ts`, and changes to `src/index.ts`,
`src/types.ts` and `wrangler.toml`. The API change is self-contained, so the
patch applies cleanly on top of that tree.

It touches:

| File | Change |
| --- | --- |
| `apps/api/migrations/0043_account_deletion.sql` | **new**: `account_deletions` (job + audit row), `account_deletion_objects` (background queue). Additive only. |
| `apps/api/src/lib/account-deletion.ts` | **new**: checks, Stripe cancel, the D1 batch, background cleanup |
| `apps/api/src/routes/account-delete.ts` | **new**: `DELETE /api/me` |
| `apps/api/src/routes/account-delete.test.ts` | **new**: 10 vitest cases |
| `apps/api/src/index.ts` | 3 hunks: two imports after the last import line; `app.route("/api", accountDeleteRoutes)` after `devicesRoutes`; one `processAccountDeletions` call in the hourly `sweep()` after the agent sweep. The 5-minute cron and the AI-search hooks are not touched. |
| `apps/api/src/share-jobs.ts` | new `ShareJobsDO.purgeAll()` method (no storage migration; same class) |
| `apps/api/README.md` | new "Account deletion" section and a project-structure line |

Verified before handing over. A copy of the main checkout's `apps/api` (as of
2026-11-17, secrets excluded) was patched with `git apply --check` (clean)
and then with `git apply`. In that patched copy:
- `tsc` reported no errors in any patched file. The only errors were imports
  from `apps/admin`, which the copy didn't include.
- The full vitest suite passed: 646 tests, including `admin-ai-search` and
  `devices`. The one suite that couldn't load was `admin-plans`, which also
  needs `apps/admin`.

## Steps for the owner

From the **main checkout** (`/Users/mike/Apps/capturecat`):

1. Apply the API patch. The patch file is in this branch at
   `docs/account-deletion-api.patch`. Copy it out, or `git show
   <branch>:docs/account-deletion-api.patch > /tmp/acct.patch`.

   ```bash
   git apply --check /tmp/acct.patch   # must print nothing
   git apply /tmp/acct.patch
   cd apps/api && npx tsc --noEmit && npx vitest run src/routes/account-delete.test.ts
   ```

2. Confirm you're on the CaptureCat Cloudflare account (`npx wrangler
   whoami`). Then apply the migration **before** deploying the Worker:

   ```bash
   cd apps/api
   npx wrangler d1 migrations apply capturecat --remote   # applies 0043 (and 0041 if it is still pending)
   ```

   Order matters. The deletion batch writes the new tables. A Worker that
   runs ahead of 0043 answers 500 `delete_failed`. Because the batch is a
   transaction, it deletes nothing. But it does so AFTER cancelling the
   subscription, so don't leave that window open.
   0041 and 0043 are independent of each other.

3. Deploy the API: `npm run deploy` in `apps/api`. No new secrets or
   bindings. It uses `STRIPE_SECRET_KEY`, `BETTER_AUTH_SECRET`, `R2`, `DB`
   and `SHARE_JOBS`, which already exist. The Cloudflare custom-hostname
   cleanup uses `CF_ZONE_ID` and `CF_SAAS_API_TOKEN` if they're set.

4. Check that the secrets are still there after the deploy (per the
   2026-10 incident): `npx wrangler secret list` should show the same set as
   before, and sign-in should still work on the web and the Mac.

5. Merge this branch for web and iOS. Deploy the web as usual. The iOS
   change ships with the next build.

## Post-deploy verification

Use a **throwaway** account, never a real customer's. Sign in on the web with
a spare Google or Apple ID.

1. **Unauthenticated / CSRF.** Each of these should be refused, and nothing
   should change:
   - `curl -i -X DELETE https://api.capturecat.so/api/me` → **403** "Origin
     not allowed" (no credentials and no Origin).
   - `curl -i -X DELETE -H 'Authorization: Bearer nope'
     https://api.capturecat.so/api/me` → **401**.
2. **Seed the throwaway account**:
   - upload one short share from the Mac or web;
   - leave a comment on it;
   - optionally assign it a plan from Admin → Users → Assign plan. That
     creates a real $0 Stripe subscription, which exercises the cancel path
     without charging anything.
3. **Team guard (optional).** Create a team with the throwaway account and
   invite a second throwaway account. Deleting the first should give **409**,
   with the team's name in the message.
4. **Delete** from web Settings → Delete account (type DELETE). Expect:
   - the toast "Your account was deleted." and a redirect to the home page;
   - the share link now 404s;
   - signing in again with the same Google or Apple ID creates a brand-new,
     empty account.
5. **Check the server side**:

   ```bash
   npx wrangler d1 execute capturecat --remote --command \
     "SELECT id, client, status, cancelled_subscriptions, counts_json, requested_at, completed_at
        FROM account_deletions ORDER BY requested_at DESC LIMIT 3"
   npx wrangler d1 execute capturecat --remote --command \
     "SELECT COUNT(*) AS left FROM account_deletion_objects"
   ```

   You should see `status = 'done'` within seconds (at the latest, after the
   next hourly sweep), and `left = 0`. The row has no email or name.
6. **Stripe.** If you assigned a plan in step 2, the Dashboard shows that
   subscription as **canceled**, with the comment "The customer deleted their
   CaptureCat account." The customer object stays, which is intended: it
   keeps the invoices.
7. **iOS** (TestFlight build). Account tab → scroll to the bottom → "Delete
   account" → "Delete Account…" → type DELETE. The app should return to the
   sign-in screen. Locally, the gate `apps/ios/scripts/ios-account-delete.sh`
   proves the same flow against the mock API.
8. **Logs.** `npx wrangler tail` during the deletion should show no `account
   delete:` errors. The hourly sweep logs `account deletions: N objects, x/y
   finished` only when it had work to do.

## App Store review notes (iOS)

`docs/ios-app-store.md` does not exist yet. Paste this into App Store
Connect → App Review Information → Notes:

> Account deletion: open the **Account** tab (third tab in the bottom bar),
> scroll to the bottom, and tap **Delete Account…** in the "Delete account"
> section. A confirmation explains what is deleted and that an active
> subscription is cancelled immediately. Type DELETE and tap Delete Account.
> The account and its data are deleted on our servers right away, the app
> signs out, removes this account's data from the device, and returns to the
> sign-in screen. No website visit or email is needed.

Screenshots taken by the gate are in the gate's `OUT` directory
(`account.png`, `confirm.png`, `refusal-409-team.png`, `signed-out.png`).

## Mac

The Mac app is distributed outside the Mac App Store (a notarized DMG with
auto-update), so 5.1.1(v) doesn't apply to it, and its Settings window has no
account-deletion entry. Mac users delete their account on the web: Settings →
Delete account. Adding a "Delete Account…" button to the Mac Settings window
later would be an AppKit/CCKit job (no NSAlert). The same `DELETE /api/me`
with the Mac's bearer token, sent with `X-CC-Client: mac`, would do it.

## Decisions taken (owner may want to revisit)

- **Comments on other people's videos are deleted.** The privacy policy (§6)
  says personal data is deleted when you close your account. When someone
  else replied to one of these comments, it is redacted in place instead
  ("Deleted account" / "This comment was deleted.") so the replies keep
  their thread. Comments that anyone left on the deleted user's own videos
  go with the videos.
- **Team owners with other members are blocked (409), not auto-transferred.**
  Handing a team and its shared library to someone is a choice only the
  owner should make. A team whose only member is the user is deleted with
  them. A team where someone else is also an owner just loses a member.
  Videos and projects the user uploaded to *someone else's* team library are
  theirs, so they are deleted too.
- **The Stripe customer is kept; subscriptions are cancelled immediately**,
  with no proration refund. Invoices are tax records (privacy policy §6:
  kept six years).
- **Blocked accounts can't self-delete.** `requireAuth` answers 403 "Account
  blocked" first. The account may be evidence, so support decides. To honour
  such a request, unblock the account and have the user delete it, or add
  an admin-triggered route that calls the same `lib/account-deletion.ts`
  functions (not built).
- **The audit record** (`account_deletions`) is kept indefinitely. It holds
  the deleted id, the client, when, how many subscriptions were cancelled,
  counts of what was removed, and an HMAC of the email address (keyed with
  `BETTER_AUTH_SECRET`), so support can confirm a deletion for an address
  without storing the address. There's no admin UI for it yet: query D1. If
  you'd rather keep no email-derived value at all, drop `email_hmac`.
- **Kept on purpose:**
  - `moderation_actions`, the admins' audit trail;
  - closed `video_reports` about the deleted videos;
  - the `rate_limits` counter, swept within a day;
  - anonymous `site_events`.
