/**
 * Sign-up attribution (migration 0030): what we know about where a new user
 * came from at the moment their row is created.
 *
 * Runs from Better Auth's user.create.after hook, inside the OAuth callback
 * request, so:
 *   • the country is Cloudflare's geo for the browser completing sign-in;
 *   • the OAuth state round-trips what the sign-in START knew — its
 *     callbackURL (the Mac app's loopback bridge is /api/desktop/complete) and,
 *     for a web sign-in, the landing attribution the page held in memory,
 *     passed as signIn.social's `additionalData` under `cc*` keys.
 *
 * The state is the signed server-side copy, but its `cc*` values came from a
 * browser, so they are re-validated here exactly like the anonymous ingest.
 * A Mac-app sign-in starts on the API with no page behind it, so it carries
 * country and `desktop` only — the source of those users shows up in the site
 * visit/download events instead.
 */

import {
  cleanTag,
  externalReferrerHost,
  normalizeLandingPath,
} from "./traffic-source";

export interface SignupAttribution {
  country: string | null;
  via: "web" | "desktop";
  referrer: string | null;
  utm: string | null;
  landing: string | null;
}

/** `|` is the column's separator, so it cannot appear inside a tag. */
const tag = (v: unknown) => cleanTag(v)?.replaceAll("|", "") || null;

export function signupAttributionFrom(
  request: Request | null | undefined,
  state: Record<string, unknown> | null | undefined,
): SignupAttribution {
  const cf = (request as (Request & { cf?: { country?: unknown } }) | null | undefined)?.cf;
  const country =
    typeof cf?.country === "string" && /^[A-Z]{2}$/.test(cf.country) ? cf.country : null;

  const callbackURL = typeof state?.callbackURL === "string" ? state.callbackURL : "";
  const via = callbackURL.includes("/api/desktop/complete") ? "desktop" : "web";

  const source = tag(state?.ccUtmSource);
  const medium = tag(state?.ccUtmMedium);
  const campaign = tag(state?.ccUtmCampaign);

  return {
    country,
    via,
    referrer: externalReferrerHost(typeof state?.ccReferrer === "string" ? state.ccReferrer : null),
    utm: source || medium || campaign ? [source ?? "", medium ?? "", campaign ?? ""].join("|") : null,
    landing: normalizeLandingPath(state?.ccLanding),
  };
}

/** utm_source back out of the stored "source|medium|campaign". */
export function utmSourceOf(signupUtm: string | null | undefined): string | null {
  return signupUtm?.split("|")[0] || null;
}

export async function recordSignupAttribution(
  db: D1Database,
  userId: string,
  a: SignupAttribution,
): Promise<void> {
  // signupVia IS NULL: written once; a second create for the same id (it
  // cannot happen, but) never overwrites the first answer.
  await db
    .prepare(
      `UPDATE user
          SET signupCountry = ?, signupVia = ?, signupReferrer = ?, signupUtm = ?, signupLanding = ?
        WHERE id = ? AND signupVia IS NULL`
    )
    .bind(a.country, a.via, a.referrer, a.utm, a.landing, userId)
    .run();
}
