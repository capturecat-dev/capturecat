/**
 * Cloudflare for SaaS — custom hostnames for Pro share domains.
 *
 * A customer's `share.acme.com` only works if Cloudflare (a) knows the
 * hostname belongs to our zone and (b) has issued a certificate for it.
 * Checking the CNAME ourselves proves neither. This module owns the three
 * calls that make a domain real: create the custom hostname when it is
 * added, read its status when the user clicks Verify, delete it when the
 * domain is removed.
 *
 * Validation is HTTP: once the customer's CNAME points at
 * CUSTOM_DOMAIN_CNAME_TARGET, Cloudflare serves the ACME token itself and
 * the hostname + certificate flip to `active` within a minute or two, with
 * nothing else for the customer to publish.
 *
 * One-time zone setup (fallback origin, CNAME target record, the `*\/*`
 * Worker route) lives in scripts/setup-saas.sh and is documented in README.
 */

import type { Env } from "../types";

export interface CustomHostname {
  id: string;
  hostname: string;
  /** "pending" | "active" | "moved" | "deleted" | … */
  status: string;
  /** "initializing" | "pending_validation" | "pending_issuance" |
   *  "pending_deployment" | "active" | "expired" | … */
  sslStatus: string;
  /** Present until the hostname is active: a TXT record proving ownership,
   *  for customers who want to pre-validate before switching DNS. */
  ownershipVerification: { type: string; name: string; value: string } | null;
  /** Human-readable reason when Cloudflare is stuck (e.g. CAA denied). */
  verificationErrors: string[];
}

export function saasConfigured(env: Env): boolean {
  return Boolean(env.CF_ZONE_ID && env.CF_SAAS_API_TOKEN);
}

export function cnameTarget(env: Env): string {
  return (env.CUSTOM_DOMAIN_CNAME_TARGET ?? "customers.capturecat.so").toLowerCase();
}

type CFEnvelope<T> = {
  success: boolean;
  result: T | null;
  errors?: Array<{ code: number; message: string }>;
};

type CFHostnameRecord = {
  id: string;
  hostname: string;
  status?: string;
  ssl?: { status?: string; validation_errors?: Array<{ message: string }> };
  ownership_verification?: { type: string; name: string; value: string };
  verification_errors?: string[];
};

function toRecord(r: CFHostnameRecord): CustomHostname {
  return {
    id: r.id,
    hostname: r.hostname,
    status: r.status ?? "pending",
    sslStatus: r.ssl?.status ?? "initializing",
    ownershipVerification: r.ownership_verification ?? null,
    verificationErrors: [
      ...(r.verification_errors ?? []),
      ...(r.ssl?.validation_errors ?? []).map((e) => e.message),
    ],
  };
}

async function cf<T>(env: Env, path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`https://api.cloudflare.com/client/v4/zones/${env.CF_ZONE_ID}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.CF_SAAS_API_TOKEN}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const body = (await res.json().catch(() => null)) as CFEnvelope<T> | null;
  if (!res.ok || !body?.success || body.result === null) {
    const detail = body?.errors?.map((e) => `${e.code}: ${e.message}`).join("; ") || `HTTP ${res.status}`;
    throw new Error(`Cloudflare for SaaS ${init.method ?? "GET"} ${path} failed — ${detail}`);
  }
  return body.result;
}

/** Register the hostname. Idempotent from our side: if Cloudflare already
 *  has it (a retry after a failed D1 write), the existing record is returned. */
export async function createCustomHostname(env: Env, hostname: string): Promise<CustomHostname> {
  try {
    const created = await cf<CFHostnameRecord>(env, "/custom_hostnames", {
      method: "POST",
      body: JSON.stringify({
        hostname,
        ssl: {
          method: "http",
          type: "dv",
          settings: { min_tls_version: "1.2" },
        },
      }),
    });
    return toRecord(created);
  } catch (err) {
    // 1406 = duplicate custom hostname. Look it up rather than fail.
    if (String(err).includes("1406")) {
      const existing = await findCustomHostname(env, hostname);
      if (existing) return existing;
    }
    throw err;
  }
}

export async function findCustomHostname(env: Env, hostname: string): Promise<CustomHostname | null> {
  const list = await cf<CFHostnameRecord[]>(
    env,
    `/custom_hostnames?hostname=${encodeURIComponent(hostname)}`,
  );
  const match = list.find((r) => r.hostname.toLowerCase() === hostname.toLowerCase());
  return match ? toRecord(match) : null;
}

export async function getCustomHostname(env: Env, id: string): Promise<CustomHostname | null> {
  try {
    return toRecord(await cf<CFHostnameRecord>(env, `/custom_hostnames/${encodeURIComponent(id)}`));
  } catch (err) {
    if (String(err).includes("1436") || String(err).includes("HTTP 404")) return null;
    throw err;
  }
}

export async function deleteCustomHostname(env: Env, id: string): Promise<void> {
  try {
    await cf<{ id: string }>(env, `/custom_hostnames/${encodeURIComponent(id)}`, { method: "DELETE" });
  } catch (err) {
    // Already gone is the outcome we wanted.
    if (String(err).includes("1436") || String(err).includes("HTTP 404")) return;
    throw err;
  }
}

/** Live = Cloudflare will route it AND serve a valid certificate. */
export function hostnameIsLive(h: CustomHostname | null): boolean {
  return h !== null && h.status === "active" && h.sslStatus === "active";
}
