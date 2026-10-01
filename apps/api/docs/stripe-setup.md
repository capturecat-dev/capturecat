# Stripe setup (Better Auth Stripe plugin)

Billing runs entirely through [`@better-auth/stripe`](https://better-auth.com/docs/plugins/stripe).
Configuration lives in one file: [`src/lib/stripe.ts`](../src/lib/stripe.ts), which
exports `buildStripePlugin(env)` for `src/lib/auth.ts` to drop into its `plugins` array.

There is **no** hand-written Stripe code left: the old `verifyStripeSignature()`
HMAC verifier, the `POST /webhooks/stripe` route, and the `stripe_customers`
table are all deleted.

---

## 1. Plans, products and prices: the plan table is the catalog

**Nothing is created in the Stripe Dashboard by hand, and no price id is
pasted anywhere.** Plans live in the D1 `plan` table and are edited in the
admin console (admin → Plans). **Saving a plan is syncing it**
([`src/lib/stripe-catalog.ts`](../src/lib/stripe-catalog.ts)):

| Stripe object | How it is found | Stored on the plan row |
|---|---|---|
| **Product** — one per plan | the stored id, else the product of a price the plan already sells, else a product tagged `metadata.plan = <name>`, else created once | `stripe_product_id` |
| **Price** — one per interval | lookup key `capturecat_<plan>_monthly` / `capturecat_<plan>_yearly` | `price_id`, `annual_price_id`, amounts, `currency` |
| **Sale coupon** — one per interval | the stored id | `stripe_sale_coupon_id`, `stripe_sale_annual_coupon_id` |

What a save does, per interval:

- **Same amount and currency** as the keyed price → reused. Saving twice
  changes nothing (the summary says *Already in sync*).
- **Different amount or currency** → a new price is created with the lookup key
  (`transfer_lookup_key: true` moves it off the old price) and the old price is
  archived. **Existing subscriptions keep the price they were sold**; only new
  checkouts get the new one.
- **Price cleared** (e.g. yearly billing turned off) → the price is archived.
- **No keyed price yet, but a known one** (the row's `price_id`, or for Pro the
  legacy `STRIPE_PRO_PRICE_ID` / `STRIPE_PRO_ANNUAL_PRICE_ID`) and the amount is
  unchanged or left blank → **adopted**: the lookup key is put on that price and
  its product is tagged `metadata.plan`. No new price, nobody moved. This is how
  production migrates (§5).

Stripe is written **first and only additively**; the plan row is written after
Stripe succeeds; only then are replaced prices archived and replaced coupons
deleted. If the row cannot be written, everything the save created in Stripe is
undone, so Stripe never sells something D1 does not know about.

Every save returns a summary — product created/updated/unchanged and, per
interval, price adopted/created/reused/archived plus the sale coupon — which
the editor shows. Plans → ⋯ → **Sync with Stripe** re-syncs one plan without
edits; **Sync all plans** does every plan (Free is never sold; a plan with no
price yet is skipped).

**Checkout reads only the plan table** (`stripePlansFromDB` in
`src/lib/plans.ts`): the row's stored price, or — for an active row with none —
the price holding its lookup key in Stripe (cached per isolate for a minute).
There is no env-var price and no fallback plan. A plan hidden in the admin
console is never offered, whatever Stripe holds; its existing subscribers keep
its features until their subscription ends.

### Sales ("a price for a period")

A plan's sale has a label, a sale price per interval, a start (blank = from
saving), a required end, and how long the discount lasts (blank = for as long
as the subscriber stays; N = their first N months). It never creates a cheaper
price: everyone is on the **regular** price, and the sale is a Stripe **coupon**
per interval — `amount_off` = regular − sale, `redeem_by` = the sale's end,
`duration` `forever` or `repeating`, `applies_to` the plan's product, metadata
`{ capturecat_plan, interval }`. Coupons are immutable, so any change deletes
the old one and creates a new one (deleting never removes a discount a
subscriber already has).

While the window is open, checkout adds that interval's coupon and caps the
session's `expires_at` at the sale's end (Stripe's 30-minute floor aside), and
`GET /api/plans` returns the sale price as `amount` with `regularAmount` to
strike through — both from `src/lib/plan-sale.ts`, so the page can never
advertise a price checkout would not charge.

### Editing prices in the Stripe Dashboard

Prefer the admin console. If you do change a price in the Dashboard, create the
new price on the plan's product, give it the plan's lookup key
(`capturecat_pro_monthly`, …) and tick **Transfer lookup key**, then archive the
old one. The catalog webhooks (§2) update the plan row. A new price *without*
the key is ignored; archiving the plan's only price stops that interval being
sold.

Use **Test mode** for development and **Live mode** for production; they are
separate catalogs, and each is synced from its own environment's admin.

## 2. Webhook endpoint

The plugin owns `POST /api/auth/stripe/webhook`.

1. Dashboard → **Developers** → **Webhooks** → **Add endpoint**
2. Endpoint URL: `https://api.capturecat.so/api/auth/stripe/webhook`
3. Select these nine events — and only these; everything else falls through to
   the `onEvent` catch-all, which just logs:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `charge.dispute.created` — cancels the disputing customer's live
     subscriptions (`cancelDisputedSubscriptions` in `src/lib/stripe.ts`);
     without it a chargeback keeps the plan running until the period ends
   - `product.updated` — keeps the plan's display name and description in step
     with its product
   - `price.created`, `price.updated`, `price.deleted` — keep the plan's price
     ids and amounts in step with the price holding its lookup key

   Every one of them is verified against the signing secret and then **re-read
   from Stripe** before it is applied (`withFreshEvents` in `src/lib/stripe.ts`),
   so a late or out-of-order delivery acts on Stripe's current state. Catalog
   events only touch the product a plan row stores (still tagged
   `metadata.plan`) and prices carrying one of our lookup keys or stored on a
   row; they never activate a plan or change its features or limits.
4. Copy the **signing secret** (`whsec_…`) → `STRIPE_WEBHOOK_SECRET`
5. **Delete the old `https://api.capturecat.so/webhooks/stripe` endpoint.** That
   route no longer exists; leaving it registered produces a stream of failed
   deliveries in the dashboard.

### Local webhook testing

The dashboard signing secret does **not** work against the Stripe CLI. Use:

```bash
stripe listen --forward-to localhost:8787/api/auth/stripe/webhook
```

and put the `whsec_…` it prints into `.dev.vars`.

## 3. Secrets

```bash
cd apps/api
npx wrangler secret put STRIPE_SECRET_KEY          # sk_live_…
npx wrangler secret put STRIPE_WEBHOOK_SECRET      # whsec_… from step 2
```

That is all billing needs. For local development copy `.dev.vars.example` →
`.dev.vars` and use test-mode values. Both are typed on `Env` in
`src/types.ts`.

**Legacy:** `STRIPE_PRO_PRICE_ID`, `STRIPE_PRO_ANNUAL_PRICE_ID` and
`STRIPE_PRO_TRIAL_DAYS` are no longer read by checkout or the pricing page.
Only the sync's one-time adoption step reads them (§5), to key the price
production already sells; it also carries the trial days over to the plan row.
Once every plan shows **Synced** in the admin, they can be deleted.

If `STRIPE_SECRET_KEY` is missing the Worker logs a loud error and Stripe calls
fail individually — deliberately, so a half-configured billing setup cannot
take down sign-in. The admin console still saves features and limits, but
refuses price and sale changes.

## 4. Database

The `subscription` table and `user.stripeCustomerId` are created by
`migrations/0003_better_auth.sql`. `migrations/0004_drop_firebase_stripe_customers.sql`
drops the retired `stripe_customers` table.

```bash
cd apps/api
npx wrangler d1 migrations apply capturecat --local     # dev
npx wrangler d1 migrations apply capturecat --remote    # prod
```

`wrangler.toml` still has a placeholder `database_id`; that must be the real id
before `--remote` works.

`migrations/0028_plan_stripe_sync.sql` adds the sync and sale columns to
`plan` (`stripe_product_id`, `popular`, `sale_*`, `stripe_sale_*coupon_id`).
Every column is additive and NULL/0 for existing rows, and the code running
before this change never reads them, so it is safe to apply before deploying.

## 5. One-time production migration (from the env-var prices)

Before this change production sold Pro through `STRIPE_PRO_PRICE_ID` /
`STRIPE_PRO_ANNUAL_PRICE_ID` because Pro's row had no price. After it, checkout
reads only the plan table, so **Pro is not for sale between the deploy and the
sync in step 4** (the pricing page shows no price, and checkout refuses Pro).
Do steps 2–4 back to back, or close that gap first: in the admin console that
is live *before* the deploy, open Pro and paste the current monthly (and
yearly) price id into its price fields — checkout then keeps working through
the plan row, and step 4 adopts the same prices from it.

1. **Migration**: `cd apps/api && npx wrangler d1 migrations apply capturecat --remote`
2. **Deploy**: `cd apps/api && npm run deploy`, then `cd apps/admin && npm run deploy`
   (and `apps/web` for the pricing page's sale display). After the API deploy,
   check `npx wrangler secret list` is not empty and sign-in still works.
3. **Webhook events**: Stripe Dashboard → Developers → Webhooks → the
   `…/api/auth/stripe/webhook` endpoint → add `product.updated`,
   `price.created`, `price.updated`, `price.deleted` (the full list is in §2).
4. **Sync**: admin → Plans → Pro → ⋯ → **Sync with Stripe** (or open Pro,
   leave the prices blank — or type the current ones — and **Save & sync**).
   The summary should read: product *Updated* (it gets `metadata.plan = pro`),
   Monthly *Adopted* from the env secret, Yearly *Adopted* if an annual price
   was set, and a note if a trial was carried over from `STRIPE_PRO_TRIAL_DAYS`.
   *Created* means a typed amount differed from what Stripe charges — check it.
   Pro now shows **Synced**. Optionally run **Sync all plans** (Business is
   skipped until it has a price).
5. **Optional cleanup**, once every sold plan shows **Synced**:
   ```bash
   cd apps/api
   npx wrangler secret delete STRIPE_PRO_PRICE_ID
   npx wrangler secret delete STRIPE_PRO_ANNUAL_PRICE_ID
   npx wrangler secret delete STRIPE_PRO_TRIAL_DAYS
   ```
   Then check `npx wrangler secret list` again.

---

## What the plugin now owns

| Concern | Before | Now |
|---|---|---|
| Signature verification | `lib/stripe.ts` → hand-rolled WebCrypto HMAC | `stripe.webhooks.constructEventAsync()` (plugin prefers the async variant) |
| `checkout.session.completed` | our route: set Firebase claims + upsert `stripe_customers` | plugin: `onCheckoutSessionCompleted` → writes `subscription` |
| `customer.subscription.updated` | our route: claims + `revokeRefreshTokens` + upsert | plugin: `onSubscriptionUpdated` |
| `customer.subscription.deleted` | our route: claims free + revoke + upsert | plugin: `onSubscriptionDeleted` |
| `customer.subscription.created` | **not handled** | plugin: `onSubscriptionCreated` |
| Customer creation | on first checkout | `createCustomerOnSignUp: true` — at sign-up |
| Checkout session creation | `apps/web` tRPC `billing.createCheckoutSession` calling `stripe.checkout.sessions.create` directly | `POST /api/auth/subscription/upgrade` |
| Billing portal | `apps/web` tRPC `billing.createPortalSession` | `POST /api/auth/subscription/billing-portal` |
| uid → customer mapping | `stripe_customers` table | `subscription.referenceId` (= Better Auth `user.id`) + `user.stripeCustomerId` |

Those were **exactly** the three events our route handled, so none of the old
webhook logic survives. Firebase custom claims and refresh-token revocation are
gone as concepts: entitlement is read from `subscription` on every request, so a
cancellation revokes on the very next API call with no cached claim to
invalidate.

**Not covered by the plugin, and intentionally not re-added:** dunning email,
`invoice.paid` / `invoice.payment_failed` bookkeeping, receipts. If any of those
are wanted later, add them under the `onEvent` hook in `src/lib/stripe.ts` — do
not create a second webhook route.

## Entitlement policy

`PAID_SUBSCRIPTION_STATUSES` in `src/lib/stripe.ts` is `active`, `trialing`,
`past_due`.

`past_due` is included on purpose: it preserves the dunning grace period the old
`stripe_customers` policy had. This is **more permissive** than Better Auth's own
`isActiveOrTrialing()` helper, which excludes `past_due`. Do not "fix" the
divergence without deciding to change the dunning behaviour.

**It is only safe with the right dunning setting.** A `past_due` subscription
keeps renewing (and Stripe keeps advancing its period), so if Billing →
Subscriptions and emails → *Manage failed payments* is set to **leave the
subscription past-due** after the last retry, a dead card keeps Pro forever.
Set it to **cancel the subscription** (or **mark it as unpaid**) — both revoke.

`hasPaidSubscription(db, userId)` is the hot-path existence check.
`subscription.referenceId` is deliberately non-unique (cancel-then-resubscribe
creates a second row), which is why it is an existence check rather than a
single-row status read.

## Endpoints

All under `basePath` = `/api/auth`:

| Method | Path |
|---|---|
| POST | `/api/auth/subscription/upgrade` |
| POST | `/api/auth/subscription/cancel` |
| POST | `/api/auth/subscription/restore` |
| POST | `/api/auth/subscription/billing-portal` |
| GET | `/api/auth/subscription/list` |
| GET | `/api/auth/subscription/success` |
| POST | `/api/auth/stripe/webhook` |

The admin plan editor (`src/routes/admin-plans.ts`, admins only):

| Method | Path | Stripe? |
|---|---|---|
| GET | `/api/admin/plans` | no |
| POST | `/api/admin/plans` | create **and sync** |
| PUT | `/api/admin/plans/:id` | save **and sync** (partial body, merged over the row) |
| POST | `/api/admin/plans/:id/stripe-sync` | re-sync without edits (adoption) |
| POST | `/api/admin/plans/stripe-sync` | re-sync every plan |
| POST | `/api/admin/plans/:id/active` | no — hide from sale / publish |
| POST | `/api/admin/plans/:id/popular` | no — "Most popular" |

### Checkout from the macOS app

Bearer-authenticated, `disableRedirect: true`, then open the returned URL in the
default browser:

```http
POST https://api.capturecat.so/api/auth/subscription/upgrade
Authorization: Bearer <session token>
Content-Type: application/json

{ "plan": "pro", "annual": false, "disableRedirect": true,
  "successUrl": "https://capturecat.so/billing/success",
  "cancelUrl":  "https://capturecat.so/pricing" }
```

`referenceId` defaults to `session.user.id`. **Clients must never send an
explicit `referenceId`** — doing so would require an `authorizeReference`
callback to police it, which is not configured.

### Checkout from the web app

`apps/web` still calls Stripe directly through its Firebase-backed tRPC
`billing` router. That is out of scope here and must move to
`better-auth/client`'s `subscription.upgrade()` against this same Worker, or it
will 401 once the Worker ships.
