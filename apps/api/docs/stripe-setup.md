# Stripe setup (Better Auth Stripe plugin)

Billing runs entirely through [`@better-auth/stripe`](https://better-auth.com/docs/plugins/stripe).
Configuration lives in one file: [`src/lib/stripe.ts`](../src/lib/stripe.ts), which
exports `buildStripePlugin(env)` for `src/lib/auth.ts` to drop into its `plugins` array.

There is **no** hand-written Stripe code left: the old `verifyStripeSignature()`
HMAC verifier, the `POST /webhooks/stripe` route, and the `stripe_customers`
table are all deleted.

---

## 1. Products and prices

The pricing page (`apps/web/app/pricing/page.tsx`) sells exactly one thing, so
there is exactly one plan.

1. Dashboard → **Product catalogue** → **Add product**
   - Name: `CaptureCat Pro`
   - Description: `Everything you need to record and share`
2. Add a **recurring** price:
   - Amount: **$10.00 USD**, billing period **Monthly**
   - Copy the price id → this is `STRIPE_PRO_PRICE_ID` (`price_…`)
3. *Optional* — add a second recurring price on the same product with billing
   period **Yearly** if you ever want to offer an annual discount.
   Copy that id → `STRIPE_PRO_ANNUAL_PRICE_ID`.
   Leave the variable unset if you are not selling annually; the code
   normalises a blank value to `undefined` so an `{ annual: true }` checkout
   can never be created against an empty price id.

> Copy the **price** id (`price_…`), not the product id (`prod_…`).

Do this twice — once in **Test mode**, once in **Live mode**. The ids differ.

## 2. Webhook endpoint

The plugin owns `POST /api/auth/stripe/webhook`.

1. Dashboard → **Developers** → **Webhooks** → **Add endpoint**
2. Endpoint URL: `https://api.capturecat.so/api/auth/stripe/webhook`
3. Select these four events — and only these; everything else falls through to
   the `onEvent` catch-all, which just logs:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
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
npx wrangler secret put STRIPE_PRO_PRICE_ID        # price_… monthly
npx wrangler secret put STRIPE_PRO_ANNUAL_PRICE_ID # optional
```

For local development copy `.dev.vars.example` → `.dev.vars` and use test-mode
values. All four are typed on `Env` in `src/types.ts`.

If `STRIPE_SECRET_KEY` or `STRIPE_PRO_PRICE_ID` is missing the Worker logs a
loud error and Stripe calls fail individually — deliberately, so a
half-configured billing setup cannot take down sign-in.

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
