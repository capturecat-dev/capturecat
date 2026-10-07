import type { DocSection } from "../types";

/**
 * Checked against README.md, LICENSE, apps/api (wrangler.toml, src/types.ts,
 * README.md, docs/oauth-setup.md, docs/stripe-setup.md, r2-cors.json,
 * scripts/make-admin.sh, scripts/setup-saas.sh, src/lib/origins.ts,
 * src/lib/auth.ts, src/lib/storage.ts, src/lib/plans.ts,
 * src/lib/entitlement.ts, src/routes/admin.ts, src/routes/admin-plans.ts,
 * src/routes/attest.ts, src/routes/screenshot.ts, migrations/*), apps/web and
 * apps/admin (wrangler.jsonc, package.json, src/server.ts, lib/api-url.ts,
 * lib/plan-fields.ts), and apps/macos (project.pbxproj, package.json,
 * scripts/*.sh, Services/AuthService.swift).
 *
 * No real ids here: every account, database or zone id is a placeholder.
 */
const CHECKED = "2026-10-07";

const CLONE = `git clone https://github.com/capturecat-dev/capturecat.git
cd capturecat
npm install`;

const CREATE_RESOURCES = `cd apps/api
npx wrangler login
npx wrangler d1 create capturecat          # prints the database_id
npx wrangler r2 bucket create capturecat`;

const WRANGLER_TOML = `# apps/api/wrangler.toml: the lines that change
routes = [{ pattern = "api.example.com", custom_domain = true }]

[[d1_databases]]
binding = "DB"
database_name = "capturecat"
database_id = "<your-database-id>"
migrations_dir = "migrations"

[vars]
BETTER_AUTH_URL = "https://api.example.com"
ATTEST_MODE = "report"`;

const FIND_DOMAIN = `grep -rn "capturecat\\.so" src --include="*.ts" | grep -v "\\.test\\.ts"`;

const MIGRATE = `npx wrangler d1 migrations apply capturecat --remote`;

const CORS = `npx wrangler r2 bucket cors set capturecat --file r2-cors.json`;

const REQUIRED_SECRETS = `openssl rand -base64 32 | npx wrangler secret put BETTER_AUTH_SECRET
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
npx wrangler secret put R2_ENDPOINT          # https://<account-id>.r2.cloudflarestorage.com

# Google sign-in
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET

# Apple sign-in (optional if Google is set)
npx wrangler secret put APPLE_CLIENT_ID      # the Services ID, not the app bundle ID
npx wrangler secret put APPLE_TEAM_ID
npx wrangler secret put APPLE_KEY_ID
cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APPLE_PRIVATE_KEY`;

const DEPLOY_API = `npm run deploy
curl https://api.example.com/api/health      # {"status":"ok"}`;

const MAKE_ADMIN = `./scripts/make-admin.sh you@example.com`;

const LOCAL_DEV = `cd apps/api
npx wrangler d1 migrations apply capturecat --local
npm run dev                                  # http://localhost:8787`;

const LIST_PLANS = `npx wrangler d1 execute capturecat --remote \\
  --command "SELECT name, is_active, features, limits FROM plan"`;

const FREE_PLAN_SQL = `-- free-plan.sql: let every signed-in user share, with 20 GB each
UPDATE plan
   SET features = json_set(features,
         '$.cloudShare', json('true'),
         '$.comments', json('true'),
         '$.customStorage', json('true')),
       limits = json_set(limits,
         '$.maxTotalStorageBytes', 21474836480,
         '$.maxFileSizeBytes', 2147483648,
         '$.maxDurationSeconds', 3600,
         '$.maxUploadsPerDay', 50),
       updated_at = datetime('now')
 WHERE name = 'free';`;

const RUN_SQL_FILE = `cd apps/api
npx wrangler d1 execute capturecat --remote --file free-plan.sql`;

const ENABLE_SSO_SQL = `UPDATE plan
   SET features = json_set(features, '$.sso', json('true'), '$.customDomain', json('true')),
       updated_at = datetime('now')
 WHERE name = 'pro';`;

const DEPLOY_WEB = `cd apps/web
VITE_API_URL=https://api.example.com VITE_SITE_URL=https://example.com npm run deploy`;

const DEPLOY_ADMIN = `cd apps/admin
VITE_API_URL=https://api.example.com VITE_SITE_URL=https://admin.example.com npm run deploy`;

const WEB_JSONC = `// apps/web/wrangler.jsonc: the parts that change
"name": "my-capturecat-web",
"routes": [
  { "pattern": "example.com", "custom_domain": true },
  { "pattern": "app.example.com", "custom_domain": true }
],
"vars": {
  "VITE_API_URL": "https://api.example.com",
  "VITE_SITE_URL": "https://example.com"
}`;

const XCODEBUILD = `cd apps/macos
xcodebuild -project CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug build`;

const FIND_APP = `xcodebuild -project CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug \\
  -showBuildSettings | grep " BUILT_PRODUCTS_DIR "
open "<built-products-dir>/CaptureCat.app"`;

const POINT_DEBUG = `defaults write <your.bundle.id> apiBaseURL https://api.example.com
defaults delete <your.bundle.id> apiBaseURL     # back to http://localhost:8787`;

export const SELF_HOSTING: DocSection = {
  id: "self-hosting",
  title: "Self-hosting",
  description: "Run the open-source CaptureCat backend on your own Cloudflare account.",
  pages: [
    {
      slug: "self-hosting",
      title: "Self-host CaptureCat: open-source screen recorder backend",
      navTitle: "Overview",
      description:
        "Self-host CaptureCat, the open-source Loom alternative: what the AGPL-3.0 code includes, what you run on Cloudflare, and how the pieces connect.",
      summary:
        "All of CaptureCat is open source under the AGPL-3.0: the Mac app, the API, the web app and the admin console. To self-host, you deploy the API, web app and admin console as Cloudflare Workers with D1 and R2, and point a build of the Mac app at your API.",
      blocks: [
        { type: "h2", text: "What's open source" },
        {
          type: "p",
          text: "The whole product lives in one repository, [github.com/capturecat-dev/capturecat](https://github.com/capturecat-dev/capturecat):",
        },
        {
          type: "table",
          head: ["Folder", "What it is", "Runs on"],
          rows: [
            ["`apps/macos`", "The native Mac app: recorder, editor and exporter", "Your Mac, built with Xcode"],
            ["`apps/api`", "The API: sign-in, uploads, share links, plans, billing", "A Cloudflare Worker with D1, R2 and a Durable Object"],
            ["`apps/web`", "The website, share pages, dashboard, web recorder and web editor", "A Cloudflare Worker"],
            ["`apps/admin`", "The admin console: users, plans, teams", "A Cloudflare Worker"],
          ],
        },
        { type: "h2", text: "What the API uses" },
        {
          type: "list",
          items: [
            "**D1** (binding `DB`): users, sessions, shares, comments, analytics, plans. The schema is the numbered SQL files in `apps/api/migrations`.",
            "**R2** (binding `R2`, bucket `capturecat`): video files, screenshots and synced project media. Uploads go straight to R2 through presigned URLs, so the API also needs an R2 S3 API key.",
            "**A Durable Object** (`SHARE_JOBS`, class `ShareJobsDO`) that tracks background share uploads per user.",
            "**An hourly cron** that clears abandoned uploads and stale rate-limit rows and trims project history to each plan's limits.",
          ],
        },
        { type: "h2", text: "The AGPL in plain words" },
        {
          type: "list",
          items: [
            "You can use, study, change and self-host CaptureCat, including for your company.",
            "If you change the code and let other people use your changed version over a network (for example, your team using your server), you must offer those users the source of your version under the AGPL-3.0.",
            "If you distribute builds, such as a Mac app, you must also make their source available under the same license.",
            "\"CaptureCat\" and its logo identify this project. Don't use them for a fork or a derived service in a way that suggests it is official.",
          ],
        },
        {
          type: "callout",
          tone: "note",
          text: "This is a summary, not legal advice. The [LICENSE](https://github.com/capturecat-dev/capturecat/blob/main/LICENSE) file in the repository is what applies.",
        },
        { type: "h2", text: "Order of setup" },
        {
          type: "steps",
          steps: [
            {
              title: "Deploy the API",
              text: "Create the D1 database and R2 bucket, set the secrets, apply the migrations and deploy. See [Deploy the API](/docs/self-hosting/api).",
            },
            {
              title: "Deploy the web app and admin console",
              text: "Build both against your API's address and deploy them. See [Deploy the web app and admin console](/docs/self-hosting/web).",
            },
            {
              title: "Decide what each plan includes",
              text: "Your server has its own plan table. Turn features on and set limits for your users. See [Plans and features](/docs/self-hosting/plans-and-features).",
            },
            {
              title: "Build the Mac app",
              text: "Build it in Xcode and point it at your API. See [Build the Mac app from source](/docs/self-hosting/build-from-source).",
            },
          ],
        },
        { type: "h2", text: "Your own domain" },
        {
          type: "p",
          text: "The code assumes the API, web app and admin console are subdomains of one parent domain, because they share a session cookie set on that domain. Plan on hosts such as `example.com`, `app.example.com`, `api.example.com` and `admin.example.com`. A few `capturecat.so` addresses in the source have to change to yours; the API and web pages list where.",
        },
        { type: "h2", text: "What stays pointed at CaptureCat" },
        {
          type: "list",
          items: [
            "The Mac app's update check reads CaptureCat's release feed (`apps/macos/CaptureCat/Services/UpdateFeed.swift`).",
            "Links in the Mac app to the pricing page, the web editor and the dashboard settings use `capturecat.so` addresses. Search the Swift sources for `capturecat.so` to change them.",
          ],
        },
      ],
      faqs: [
        {
          question: "Is CaptureCat open source?",
          answer:
            "Yes. The Mac app, the API, the web app and the admin console are all in one public repository under the GNU AGPL-3.0.",
        },
        {
          question: "Can I self-host CaptureCat as a Loom alternative for my team?",
          answer:
            "Yes. Deploy the API, web app and admin console to your own Cloudflare account, build the Mac app against your API, and your team's recordings, share links, comments and analytics live on your infrastructure.",
        },
        {
          question: "Do I need Stripe to self-host CaptureCat?",
          answer:
            "No. Stripe is optional. Without it you grant features by editing your plan table or by marking users as testers in the admin console.",
        },
        {
          question: "What does self-hosting CaptureCat run on?",
          answer:
            "Cloudflare Workers, with a D1 database, an R2 bucket and a Durable Object for the API. The web app and admin console are two more Workers.",
        },
      ],
      related: ["self-hosting/api", "self-hosting/web", "self-hosting/plans-and-features", "self-hosting/build-from-source"],
      lastModified: CHECKED,
    },
    {
      slug: "self-hosting/api",
      title: "Deploy the CaptureCat API on Cloudflare Workers",
      navTitle: "Deploy the API",
      description:
        "Deploy the self-hosted CaptureCat API: create D1 and R2, edit wrangler.toml, apply migrations, set every required and optional secret, and deploy.",
      summary:
        "The API is one Cloudflare Worker. Create a D1 database and an R2 bucket named `capturecat`, set a handful of secrets, apply the migrations with `wrangler d1 migrations apply`, and run `npm run deploy` in `apps/api`.",
      blocks: [
        { type: "h2", text: "Before you start" },
        {
          type: "list",
          items: [
            "A Cloudflare account, with the domain you will use added to it.",
            "Node.js and npm. Wrangler is installed with the repository's dependencies.",
            "A Google OAuth client, an Apple Sign in with Apple key, or both. At least one is needed or nobody can sign in.",
          ],
        },
        { type: "h2", text: "Deploy" },
        {
          type: "steps",
          steps: [
            {
              title: "Clone and install",
              text: "Clone the repository and install dependencies from its root (it is an npm workspace).",
            },
            {
              title: "Create the database and bucket",
              text: "From `apps/api`, create a D1 database and an R2 bucket. Name the bucket `capturecat`: the code uses that name directly (`CAPTURECAT_BUCKET` in `src/lib/storage.ts`, and in `src/routes/screenshot.ts` and `src/routes/cloud-projects.ts`).",
            },
            {
              title: "Edit wrangler.toml",
              text: "In `apps/api/wrangler.toml`, set `routes` to your API host, paste your `database_id`, and set `BETTER_AUTH_URL` to the API's public `https://` address. OAuth callbacks are built from it. Leave the Durable Object, migrations and cron blocks as they are.",
            },
            {
              title: "Point the code at your domain",
              text: "Three places name `capturecat.so` and decide whether sign-in works: `webOrigins` in `src/lib/origins.ts` (browser origins allowed to call the API), `shareBaseURL` in the same file (the address share links are built on), and the `crossSubDomainCookies` domain in `src/lib/auth.ts` (set it to your parent domain, such as `.example.com`). The command below lists every remaining mention.",
            },
            {
              title: "Apply the migrations",
              text: "This creates every table and seeds the Free, Pro and Business plans. Run it again whenever you pull new migrations, before you deploy.",
            },
            {
              title: "Allow browser access to the bucket",
              text: "The web editor reads media from R2 and the web recorder uploads to it from the browser. Replace the `capturecat.so` origins in `apps/api/r2-cors.json` with your web hosts, then apply the file.",
            },
            {
              title: "Set the required secrets",
              text: "Run `wrangler secret put` for each value. The R2 keys come from **R2 → Manage API tokens** with Object Read & Write on the bucket.",
            },
            {
              title: "Deploy and check",
              text: "Run `npm run deploy` in `apps/api`, then request `/api/health`.",
            },
            {
              title: "Register the sign-in callbacks",
              text: "For Google, add `https://api.example.com/api/auth/callback/google` to the OAuth client's authorized redirect URIs (type **Web application**). For Apple, add your API host as a domain of the Services ID and `https://api.example.com/api/auth/callback/apple` as its return URL.",
            },
            {
              title: "Make yourself an admin",
              text: "Sign in once (on the web app or the Mac app), then run `scripts/make-admin.sh` from `apps/api`. The admin console is only open to users with the admin role.",
            },
          ],
        },
        { type: "code", lang: "bash", caption: "Clone and install", code: CLONE },
        { type: "code", lang: "bash", caption: "Create the D1 database and the R2 bucket", code: CREATE_RESOURCES },
        { type: "code", lang: "toml", caption: "wrangler.toml", code: WRANGLER_TOML },
        { type: "code", lang: "bash", caption: "List the remaining `capturecat.so` mentions (run in `apps/api`)", code: FIND_DOMAIN },
        { type: "code", lang: "bash", caption: "Apply the migrations", code: MIGRATE },
        { type: "code", lang: "bash", caption: "Apply the bucket's CORS rules", code: CORS },
        { type: "code", lang: "bash", caption: "Required secrets", code: REQUIRED_SECRETS },
        { type: "code", lang: "bash", caption: "Deploy and check", code: DEPLOY_API },
        { type: "code", lang: "bash", caption: "Promote your account to admin", code: MAKE_ADMIN },
        {
          type: "callout",
          tone: "warning",
          title: "Treat BETTER_AUTH_SECRET as permanent",
          text: "It signs session cookies and validates the Mac app's session tokens. Changing it signs every user out, on the web and on every Mac.",
        },
        { type: "h2", text: "Required settings" },
        {
          type: "table",
          head: ["Name", "Kind", "What it does"],
          rows: [
            ["`BETTER_AUTH_URL`", "var", "The API's public origin. OAuth callback URLs are built from it."],
            ["`BETTER_AUTH_SECRET`", "secret", "Signs sessions. Generate with `openssl rand -base64 32`."],
            ["`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`", "secrets", "R2 S3 API credentials used to sign upload and download URLs. The endpoint is `https://<account-id>.r2.cloudflarestorage.com`."],
            ["`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`", "secrets", "Google sign-in. Needed for the admin console, which signs in with Google."],
            ["`APPLE_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`", "secrets", "Sign in with Apple. The client ID is the Services ID, not the app's bundle ID."],
          ],
        },
        { type: "h2", text: "Optional settings" },
        {
          type: "p",
          text: "Each of these turns on one capability. Leave it unset and only that capability is unavailable; the rest of the API keeps working. A capability also has to be enabled on a plan before anyone can use it: see [Plans and features](/docs/self-hosting/plans-and-features).",
        },
        {
          type: "table",
          head: ["Name", "Kind", "Enables"],
          rows: [
            ["`STORAGE_CREDENTIALS_KEY`", "secret", "[Custom storage](/docs/custom-storage): encrypts users' bucket keys. Generate with `openssl rand -base64 32` and never change it, or every connected bucket must be reconnected."],
            ["`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`", "secrets", "Paid checkout, the customer portal, live prices on the pricing page, and syncing plans to Stripe from the admin console."],
            ["`CF_ACCOUNT_ID`, `BROWSER_RENDERING_TOKEN`", "var, secret", "Web page capture from the Mac app and the screenshot API, through Cloudflare Browser Rendering. Without them those requests answer `503 not_configured`."],
            ["`SCREENSHOT_URL_BLOCKLIST`", "var", "Extra hostnames the screenshot renderer refuses, comma-separated, on top of the built-in private-network guard."],
            ["`GEMINI_API_KEY`", "secret", "AI titles, summaries and chapters for shares."],
            ["`CF_ZONE_ID`, `CF_SAAS_API_TOKEN`, `CUSTOM_DOMAIN_CNAME_TARGET`", "var, secret, var", "[Custom share domains](/docs/teams/custom-domains) through Cloudflare for SaaS. Without them a domain can be added but never goes live."],
            ["`TURNSTILE_SECRET`", "secret", "Cloudflare Turnstile check on the website's beta sign-up form."],
            ["`ATTEST_MODE`", "var", "App Attest checks on Mac app requests: `off`, `report` (log only, the default) or `enforce`."],
            ["`BETTER_AUTH_TRUSTED_ORIGINS`", "var", "Extra browser origins to trust, comma-separated."],
          ],
        },
        {
          type: "callout",
          tone: "warning",
          title: "Keep ATTEST_MODE at report or off",
          text: "`enforce` only accepts Mac builds that match the App ID in `src/routes/attest.ts`. A Mac app you build with your own team and bundle ID would be refused.",
        },
        { type: "h2", text: "Stripe webhook" },
        {
          type: "p",
          text: "If you use Stripe, add a webhook endpoint at `https://api.example.com/api/auth/stripe/webhook` with these events: `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `charge.dispute.created`, `product.updated`, `price.created`, `price.updated` and `price.deleted`. Its signing secret is `STRIPE_WEBHOOK_SECRET`. Prices are created from the admin console when you save a plan.",
        },
        { type: "h2", text: "Custom share domains" },
        {
          type: "p",
          text: "`apps/api/scripts/setup-saas.sh` does the one-time Cloudflare for SaaS setup on your zone: it creates the record customers point their CNAME at and makes it the fallback origin. Run it with `CF_API_TOKEN` and `CF_ZONE_ID` set. It does not route customer hostnames to the web app.",
        },
        { type: "h2", text: "Run it locally" },
        {
          type: "p",
          text: "Put local values in `apps/api/.dev.vars` (it is gitignored), with `BETTER_AUTH_URL=http://localhost:8787`. Google sign-in works locally if you add `http://localhost:8787/api/auth/callback/google` as a redirect URI; Apple refuses `localhost` return URLs. `npm run dev` at the repository root starts all the local servers together.",
        },
        { type: "code", lang: "bash", caption: "Local API", code: LOCAL_DEV },
      ],
      faqs: [
        {
          question: "Which secrets does the self-hosted CaptureCat API need?",
          answer:
            "`BETTER_AUTH_SECRET`, the three R2 values (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`), and Google or Apple sign-in credentials. Everything else, including Stripe, is optional.",
        },
        {
          question: "Can I rename the R2 bucket?",
          answer:
            "Not without changing code: the bucket name `capturecat` is used directly in `src/lib/storage.ts`, `src/routes/screenshot.ts` and `src/routes/cloud-projects.ts`. Bucket names are per account, so `capturecat` is free to use in yours.",
        },
        {
          question: "Do I run the migrations before or after deploying?",
          answer:
            "Before. New code can read tables a migration adds, so apply `wrangler d1 migrations apply capturecat --remote` first, then deploy.",
        },
      ],
      related: ["self-hosting/web", "self-hosting/plans-and-features", "self-hosting"],
      lastModified: CHECKED,
    },
    {
      slug: "self-hosting/plans-and-features",
      title: "Plans and feature gates on a self-hosted CaptureCat server",
      navTitle: "Plans and features",
      description:
        "Control what users get on a self-hosted CaptureCat server: turn on custom storage, teams or SSO for any plan in the admin console or with SQL json_set.",
      summary:
        "On your own server, the `plan` table decides every feature and limit. Turn on any feature, for any plan, in the admin console or with one SQL statement; anything not switched on is denied.",
      blocks: [
        { type: "h2", text: "How plans work" },
        {
          type: "list",
          items: [
            "Each row of the D1 `plan` table has a `name`, a `features` JSON object of true/false gates and a `limits` JSON object of numbers. The migrations seed `free`, `pro` and `business` (Business starts hidden).",
            "**Deny by default.** A missing key, or one with a bad value, reads as `false` or `0`. Unknown keys are ignored. Nothing is granted by accident.",
            "Every request resolves the user to one row. A Stripe subscription that is active, trialing or past due uses its plan's row, even if that plan is hidden. A user marked **tester** uses the `pro` row. Everyone else uses `free`.",
            "If a subscription names a plan that no longer exists, the user gets `free`. If the `free` row itself is missing, every feature is denied.",
          ],
        },
        {
          type: "callout",
          tone: "warning",
          title: "Never rename a plan's name",
          text: "Subscriptions store the plan `name`. Renaming `pro`, say, moves every Pro subscriber to Free. Change the display name instead.",
        },
        { type: "h2", text: "Features" },
        {
          type: "table",
          head: ["Key", "Admin console label", "What it gates", "Also needs"],
          rows: [
            ["`cloudShare`", "Cloud sharing", "Uploading and share links. Also checked when a share is viewed, so turning it off pauses existing links.", "The R2 secrets"],
            ["`comments`", "Comments", "Viewer comments on shares.", "`cloudShare`"],
            ["`imageUpload`", "Screenshots", "Storing rendered screenshots in the cloud.", "Storage space"],
            ["`webCapture`", "URL capture", "Web page capture from the Mac app.", "`CF_ACCOUNT_ID`, `BROWSER_RENDERING_TOKEN`"],
            ["`screenshotApi`", "Screenshot API", "Screenshot renders requested with an API key.", "`CF_ACCOUNT_ID`, `BROWSER_RENDERING_TOKEN`"],
            ["`teams`", "Teams", "Putting videos and projects in a team library.", "Nothing"],
            ["`sso`", "Enterprise SSO", "Registering an OIDC or SAML identity provider.", "Nothing"],
            ["`customDomain`", "Custom domain", "Share pages on the user's own domain.", "`CF_ZONE_ID`, `CF_SAAS_API_TOKEN`"],
            ["`aiSummaries`", "AI summaries", "Server-side AI titles, summaries and chapters.", "`GEMINI_API_KEY`"],
            ["`customStorage`", "Custom storage", "Share videos in the user's own S3-compatible bucket.", "`STORAGE_CREDENTIALS_KEY`"],
            ["`removeWatermark`", "No watermark", "Nothing at present: no CaptureCat mark is added to exports on any plan.", "Nothing"],
          ],
        },
        { type: "h2", text: "Limits" },
        {
          type: "table",
          head: ["Key", "Meaning", "When 0"],
          rows: [
            ["`maxTotalStorageBytes`", "Total cloud storage per user, in bytes", "No uploads, except to the user's own bucket"],
            ["`maxFileSizeBytes`", "Largest single share upload, in bytes", "No uploads"],
            ["`maxDurationSeconds`", "Longest shared video, in seconds", "No length limit"],
            ["`maxUploadsPerDay`", "New shares per UTC day", "No uploads"],
            ["`maxScreenshotsPerMonth`", "Web page and API screenshot renders per UTC month", "None"],
            ["`maxHistoryDays`", "Days unnamed project versions are kept", "Only the current version"],
            ["`maxNamedVersions`", "Named versions kept per project", "Naming not included"],
          ],
        },
        { type: "h2", text: "Change a plan in the admin console" },
        {
          type: "steps",
          steps: [
            {
              title: "Open Plans",
              text: "Sign in to your admin console and open **Plans**.",
            },
            {
              title: "Edit the plan",
              text: "Click the plan's row (or **⋯ → Edit…**). Tick the features you want and enter limits in bytes, seconds or counts.",
            },
            {
              title: "Save",
              text: "Click **Save** (**Save & sync** when Stripe is configured). Without `STRIPE_SECRET_KEY`, features and limits save normally but price changes are refused.",
            },
          ],
        },
        {
          type: "p",
          text: "**Publish** and **Hide from sale** in a plan's **⋯** menu control whether it can be bought. Hiding a plan stops new checkouts only; people already subscribed keep it.",
        },
        { type: "h2", text: "Change a plan with SQL" },
        {
          type: "p",
          text: "`json_set` edits one key and leaves the others alone. Run statements with `wrangler d1 execute` from `apps/api`.",
        },
        { type: "code", lang: "bash", caption: "See every plan", code: LIST_PLANS },
        { type: "code", lang: "sql", caption: "Give everyone sharing on Free", code: FREE_PLAN_SQL },
        { type: "code", lang: "bash", caption: "Run a SQL file", code: RUN_SQL_FILE },
        { type: "code", lang: "sql", caption: "Add SSO and custom domains to Pro", code: ENABLE_SSO_SQL },
        {
          type: "callout",
          tone: "tip",
          text: "Signed-in requests see a plan change straight away. Public share pages cache the owner's plan for up to a minute.",
        },
        { type: "h2", text: "Running without Stripe" },
        {
          type: "p",
          text: "Without Stripe nobody can buy a plan, so everyone is on `free` unless you mark them as testers. Two ways to give people features:",
        },
        {
          type: "list",
          items: [
            "**Raise the Free plan** with the SQL above or in the admin console. Everyone who signs in gets it.",
            "**Mark people as testers** in the admin console: **Users → Make tester**. Testers get the `pro` row, so you can keep Free closed and open Pro to the people you choose.",
          ],
        },
      ],
      faqs: [
        {
          question: "How do I enable custom storage on a self-hosted CaptureCat server?",
          answer:
            "Set the `STORAGE_CREDENTIALS_KEY` secret on the API, then tick Custom storage on the plan in the admin console, or set `$.customStorage` to `true` with `json_set`. The migrations already turn it on for Pro and Business.",
        },
        {
          question: "Can I give every user all features on my own server?",
          answer:
            "Yes. Turn every feature on in the `free` plan and set its limits. Each feature that depends on an outside service, such as web capture or AI summaries, also needs that service's secret.",
        },
      ],
      related: ["self-hosting/api", "account/plans", "custom-storage"],
      lastModified: CHECKED,
    },
    {
      slug: "self-hosting/web",
      title: "Deploy the CaptureCat web app and admin console",
      navTitle: "Deploy web and admin",
      description:
        "Deploy the self-hosted CaptureCat web app and admin console as Cloudflare Workers: VITE_API_URL, VITE_SITE_URL, wrangler.jsonc routes and host names.",
      summary:
        "The web app (`apps/web`) and the admin console (`apps/admin`) are TanStack Start apps deployed as Cloudflare Workers with `npm run deploy`. Both are built against your API's address, set with `VITE_API_URL` and `VITE_SITE_URL`.",
      blocks: [
        { type: "h2", text: "Settings" },
        {
          type: "table",
          head: ["Variable", "Used by", "Value"],
          rows: [
            ["`VITE_API_URL`", "Web app, admin console", "Your API's origin, such as `https://api.example.com`"],
            ["`VITE_SITE_URL`", "Web app", "The website's origin, such as `https://example.com`. Sign-in and checkout return here."],
            ["`VITE_SITE_URL`", "Admin console", "The admin console's own origin, such as `https://admin.example.com`"],
            ["`VITE_TURNSTILE_SITE_KEY`", "Web app (optional)", "Your Turnstile site key for the beta sign-up form, paired with the API's `TURNSTILE_SECRET`"],
          ],
        },
        {
          type: "p",
          text: "These are read when the app is built, so set them in the environment of the build command. Keep the `vars` in each `wrangler.jsonc` in step with them. Neither app holds any other secrets; identity and billing live on the API.",
        },
        { type: "h2", text: "Deploy the web app" },
        {
          type: "steps",
          steps: [
            {
              title: "Edit wrangler.jsonc",
              text: "In `apps/web/wrangler.jsonc`, give the Worker your own `name`, replace the `routes` with your hostnames, and set the `vars`.",
            },
            {
              title: "Tell the server its hostnames",
              text: "`apps/web/src/server.ts` treats any host not in `CAPTURECAT_HOSTS` as a customer's custom share domain. Replace the `capturecat.so` hosts in that set, and in the canonical-host redirect below it, with yours. `*.workers.dev` and `localhost` already count as first-party.",
            },
            {
              title: "Build and deploy",
              text: "`npm run deploy` runs `vite build` and then `wrangler deploy`.",
            },
          ],
        },
        { type: "code", lang: "text", caption: "apps/web/wrangler.jsonc", code: WEB_JSONC },
        { type: "code", lang: "bash", caption: "Deploy the web app", code: DEPLOY_WEB },
        { type: "h2", text: "Deploy the admin console" },
        {
          type: "p",
          text: "Edit `apps/admin/wrangler.jsonc` the same way (`name`, `routes` with your admin host, `vars`), then deploy. The console signs in with Google, so the API needs Google credentials. Anyone without the admin role gets a 404; grant the role with `apps/api/scripts/make-admin.sh` as shown in [Deploy the API](/docs/self-hosting/api).",
        },
        { type: "code", lang: "bash", caption: "Deploy the admin console", code: DEPLOY_ADMIN },
        { type: "h2", text: "Connect them to the API" },
        {
          type: "list",
          items: [
            "Add the web app's and admin console's origins to `webOrigins` in `apps/api/src/lib/origins.ts` (or to `BETTER_AUTH_TRUSTED_ORIGINS`). The API refuses signed-in browser requests from any other origin.",
            "Set the API's cookie domain in `apps/api/src/lib/auth.ts` to the parent domain all three share, such as `.example.com`.",
            "Add the web hosts to `apps/api/r2-cors.json` and apply it, so the web recorder and web editor can reach the bucket.",
          ],
        },
        {
          type: "callout",
          tone: "warning",
          text: "Never add a zone-wide `*/*` route to the web Worker. It captures the API's and admin console's hostnames on the same zone and takes them offline.",
        },
        { type: "h2", text: "Run them locally" },
        {
          type: "p",
          text: "`npm run dev` in `apps/web` serves the web app on port 3200, and in `apps/admin` serves the console on port 3300. `apps/web/.env.development` points the web app at a local API on port 8787. A local API trusts these ports automatically.",
        },
      ],
      related: ["self-hosting/api", "self-hosting/plans-and-features", "web-app"],
      lastModified: CHECKED,
    },
    {
      slug: "self-hosting/build-from-source",
      title: "Build the CaptureCat Mac app from source with Xcode",
      navTitle: "Build the Mac app",
      description:
        "Build the open-source CaptureCat Mac app from source with Xcode and xcodebuild, sign it with your own team, and point it at a self-hosted API.",
      summary:
        "Open `apps/macos/CaptureCat.xcodeproj` in Xcode 26 or later, choose your own signing team, and build. The app runs on macOS 14 or later; notarization is only needed to give the app to other people.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Requirements" },
        {
          type: "list",
          items: [
            "Xcode 26 or later. The app uses macOS 26 APIs behind availability checks, so it needs the macOS 26 SDK.",
            "macOS 14 or later to run the app.",
            "An Apple developer account for signing. Swift packages (Sparkle and WhisperKit) are fetched by Xcode on the first build.",
          ],
        },
        { type: "h2", text: "Build" },
        {
          type: "steps",
          steps: [
            {
              title: "Clone the repository",
              text: "`git clone https://github.com/capturecat-dev/capturecat.git`. The Mac app needs nothing from npm.",
            },
            {
              title: "Set your own signing",
              text: "Open `apps/macos/CaptureCat.xcodeproj`, select the CaptureCat target and open **Signing & Capabilities**. Choose your team and change the bundle identifier to one you own, such as `com.yourname.CaptureCat`, since the original belongs to CaptureCat's team. If Xcode reports a capability your team can't provision, remove it for your build.",
            },
            {
              title: "Build",
              text: "Press Run in Xcode, or build from Terminal with `xcodebuild`. `npm run build` in `apps/macos` runs the same build with `-allowProvisioningUpdates`.",
            },
            {
              title: "Open the app",
              text: "Xcode launches it for you. After a command-line build, find the app in the build products folder.",
            },
            {
              title: "Grant permissions",
              text: "macOS asks for Screen Recording, and camera and microphone when you use them, for your build separately from any installed copy of CaptureCat.",
            },
          ],
        },
        { type: "code", lang: "bash", caption: "Build from Terminal", code: XCODEBUILD },
        { type: "code", lang: "bash", caption: "Find and open the built app", code: FIND_APP },
        { type: "h2", text: "Point the app at your API" },
        {
          type: "p",
          text: "The API address comes from `CaptureCatAPI.baseURL` in `apps/macos/CaptureCat/Services/AuthService.swift`:",
        },
        {
          type: "list",
          items: [
            "**Debug builds** talk to `http://localhost:8787` (a local API) by default. To use a deployed API instead, set the `apiBaseURL` default to an `https://` address, as below. Use your bundle identifier as the domain.",
            "**Release builds** always use the address written in `baseURL`, and ignore `apiBaseURL`. Change the Release value there to your API, such as `https://api.example.com`.",
          ],
        },
        { type: "code", lang: "bash", caption: "Point a Debug build at a deployed API", code: POINT_DEBUG },
        {
          type: "callout",
          tone: "note",
          text: "Recording, editing and export work without any API. You only need one to sign in, share and sync.",
        },
        { type: "h2", text: "Notarization" },
        {
          type: "p",
          text: "Builds you run on your own Mac don't need to be notarized. To give the app to other people, sign it with a Developer ID certificate and notarize it. `apps/macos/scripts/create_release_dmg.sh` does both and packages a DMG: set its `SIGNING_IDENTITY` to your own Developer ID certificate and `NOTARY_PROFILE` to your stored `notarytool` profile first.",
        },
        { type: "h2", text: "Verification gates" },
        {
          type: "p",
          text: "`npm test` in `apps/macos` runs `scripts/run-gates.sh`, the headless checks that compare the editor preview against the exporter. It needs a built app, so build first.",
        },
      ],
      faqs: [
        {
          question: "Can I build CaptureCat without paying for an Apple developer account?",
          answer:
            "Xcode needs a signing team to build the sandboxed app. A personal team may be refused some of the app's capabilities; remove those for your own build if Xcode reports them.",
        },
        {
          question: "Does a self-built CaptureCat app use capturecat.so?",
          answer:
            "A Debug build talks to a local API on port 8787 until you set `apiBaseURL`. A Release build talks to the address in `CaptureCatAPI.baseURL`, which is `https://api.capturecat.so` until you change it.",
        },
      ],
      related: ["self-hosting/api", "self-hosting", "getting-started/install"],
      lastModified: CHECKED,
    },
  ],
};
