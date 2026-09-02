import type { ShareJobsDO } from "./share-jobs";

export interface Env {
  R2: R2Bucket;
  DB: D1Database;
  /** Per-user background share-upload job tracker (Durable Object). */
  SHARE_JOBS: DurableObjectNamespace<ShareJobsDO>;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  R2_ENDPOINT: string;
  APP_TOKEN: string;
  /** Secret — Cloudflare Turnstile server key for the beta sign-up form. */
  TURNSTILE_SECRET_KEY?: string;

  /** Secret — HMAC key for session cookies AND for validating the raw session
   *  tokens the bearer plugin accepts. Rotating it logs out every user and
   *  invalidates every Keychain-stored desktop token. Treat as permanent. */
  BETTER_AUTH_SECRET: string;
  /** Optional, dev only — extra trusted origins, comma-separated. Set to
   *  "http://localhost:3000" in .dev.vars so the local Next.js app can sign in.
   *  Deliberately NOT in wrangler.toml: production must not trust localhost. */
  BETTER_AUTH_TRUSTED_ORIGINS?: string;
  /** Public origin this Worker is served from, e.g. "https://api.capturecat.so".
   *  Must be set, or Better Auth builds OAuth callback URLs against localhost. */
  BETTER_AUTH_URL: string;

  /** Secret — Google Cloud OAuth client ("Web application" type). */
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;

  /** Secret — the Apple SERVICES ID (e.g. "so.capturecat.auth").
   *  NOT the app bundle id; using that returns invalid_client. */
  APPLE_CLIENT_ID: string;
  APPLE_TEAM_ID: string;
  /** Secret — the 10 chars from AuthKey_XXXXXXXXXX.p8. */
  APPLE_KEY_ID: string;
  /** Secret — the full .p8 contents, BEGIN/END lines included. */
  APPLE_PRIVATE_KEY: string;

  STRIPE_SECRET_KEY: string;
  /** Secret — signing secret for POST /api/auth/stripe/webhook (`whsec_…`). */
  STRIPE_WEBHOOK_SECRET: string;
  /** Secret — recurring monthly price id for CaptureCat Pro (`price_…`). */
  STRIPE_PRO_PRICE_ID: string;
  /** Optional — free-trial length in days for the Pro plan. A trial is a real
   *  Stripe subscription in status `trialing`, which counts as paid. Unset or
   *  0 means no trial. */
  STRIPE_PRO_TRIAL_DAYS?: string;
  /** Secret — optional annual price id for CaptureCat Pro (`price_…`). */
  STRIPE_PRO_ANNUAL_PRICE_ID?: string;
  /** Secret — server-side Gemini key for /api/ai/* (never ships in the app). */
  GEMINI_API_KEY?: string;
  /** Secret — Cloudflare Turnstile secret used by POST /api/beta to verify the
   *  widget token via siteverify. The matching PUBLIC site key lives in the web
   *  app as NEXT_PUBLIC_TURNSTILE_SITE_KEY. Optional in the type because a
   *  locally-running Worker skips verification when it is unset (see
   *  routes/beta.ts); production must have it set or every sign-up 400s. */
  TURNSTILE_SECRET?: string;
  /** "off" | "report" (default) | "enforce" — App Attest assertion policy. */
  ATTEST_MODE?: string;

  /** Cloudflare account id hosting the Browser Rendering ("Browser Run")
   *  REST API — /api/screenshot/take is 503 without it. Not secret, but set
   *  alongside the token so both live in one place. */
  CF_ACCOUNT_ID?: string;
  /** Secret — API token with "Browser Rendering - Edit" permission. The
   *  screenshot engine calls the REST quick-action endpoint with it; see
   *  src/lib/screenshot/renderer.ts for why REST beats the browser binding
   *  on cost for this workload. */
  BROWSER_RENDERING_TOKEN?: string;
  /** Optional — comma-separated hostnames the screenshot API must refuse
   *  (each entry blocks the host and all subdomains), on top of the built-in
   *  private-range / localhost SSRF guard in lib/screenshot/params.ts. */
  SCREENSHOT_URL_BLOCKLIST?: string;
}

export interface AuthUser {
  /** Better Auth `user.id`. Stored verbatim in shared_videos.uid, the
   *  attest_* tables' uid columns and the rate_limits key prefix — those all
   *  used to hold a Firebase uid and needed no migration (zero existing users). */
  uid: string;
  email?: string;
  /**
   * Server-owned flags read off the `user` row — NOT client input. Both are
   * declared `input: false` in the Better Auth config, so no sign-up or update
   * payload can set them.
   *
   * `paid`/`status` are deliberately ABSENT: paid entitlement is derived from
   * the `subscription` table on every request (see lib/entitlement.ts), so
   * there is no cached claim that can go stale after a cancellation.
   */
  claims?: {
    tester: boolean;
    blocked: boolean;
  };
}

/** Server-resolved entitlement — set by requireEntitlement. */
export type EntitlementTier = "free" | "tester" | "paid";

export interface VideoMetadata {
  videoId: string;
  uid: string;
  fileName: string;
  contentType: string;
  fileSizeBytes: number;
  durationSeconds: number;
  r2Key: string;
  url: string;
  isPrivate: boolean;
  status: "pending" | "ready";
  createdAt: string;
  /** Viewer comments opt-in — set by the uploader at share time. */
  commentsEnabled: boolean;
  /** JSON array of annotation markers in output-time seconds, or null. */
  annotationsJson: string | null;
  /** Originating editor project UUID, for capturecat:// deep links. */
  projectId: string | null;
  /** Viewers may download the original file from the share page. */
  allowDownload: boolean;
  /** SHA-256("<videoId>:<password>") hex, null = no password gate. */
  passwordHash: string | null;
  /** ISO date after which the share refuses to play, null = never. */
  expiresAt: string | null;
  /** Max distinct viewer sessions, null/0 = unlimited. */
  maxViews: number | null;
  /** Owner brand accent for share-page chrome, "#RRGGBB" or null. */
  brandAccent: string | null;
  /** Which video_versions row the share link currently plays (migration 0017). */
  currentVersion: number;
  /** Share page lists older versions and lets viewers play them. */
  showVersionHistory: boolean;
  /** Call-to-action button on the share page (migration 0018). */
  ctaLabel: string | null;
  ctaUrl: string | null;
  /** Listed on the owner's public profile page (migration 0019). A public
   *  share link and a listed video are deliberately separate choices. */
  profileVisible: boolean;
  /** Content type of the owner-uploaded custom thumbnail in R2 at
   *  `thumbs/{videoId}` (migration 0020), or null when none exists. */
  thumbnailType: string | null;
  /** Unquoted ETag recorded at /complete; null for pre-0021 rows. */
  etag?: string | null;
}

/** One historical file of a shared video (migration 0017). */
export interface VideoVersion {
  versionId: string;
  videoId: string;
  versionNumber: number;
  r2Key: string;
  fileSizeBytes: number;
  durationSeconds: number;
  status: "pending" | "ready";
  createdAt: string;
}

/** One annotation marker shipped to the share page. Times are seconds into
 *  the exported file (already retimed through trim + speed regions). */
export interface AnnotationMarker {
  start: number;
  end: number;
  label?: string;
  autoPause?: boolean;
  pauseDuration?: number;
}

export interface VideoComment {
  commentId: string;
  videoId: string;
  authorName: string;
  body: string;
  videoTime: number;
  createdAt: string;
}

export type Variables = {
  user: AuthUser;
  /** Set by requireAuth alongside `user`. `expiresAt` is ISO-8601 and slides
   *  forward server-side as the session is used, WITHOUT the token changing —
   *  the desktop app mirrors it into the Keychain so a continuously active
   *  user is never signed out at the 30-day mark. */
  session: { expiresAt: string };
  entitlement: { uid: string; tier: EntitlementTier };
};
