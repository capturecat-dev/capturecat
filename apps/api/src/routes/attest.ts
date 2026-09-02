/**
 * App Attest endpoints + assertion middleware.
 *
 * Rollout: ATTEST_MODE env — "off" | "report" (default; verify + log, never
 * block) | "enforce" (privileged routes 401 without a valid assertion,
 * except uids present in attest_exemptions — Intel Macs / macOS < 14).
 */

import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import {
  verifyAttestation,
  verifyAssertion,
  b64ToBytes,
} from "../lib/app-attest";

const APP_ID = "E52HU87CX9.so.capturecat.CaptureCat";
const CHALLENGE_TTL_SEC = 300;

export const attestRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/**
 * POST /attest/challenge — random 32-byte nonce, stored per-uid, 5 min TTL.
 * The client folds it into attestation (key registration).
 */
attestRoutes.post("/attest/challenge", requireAuth, async (c) => {
  const user = c.get("user");
  const nonce = crypto.getRandomValues(new Uint8Array(32));
  const nonceB64 = btoa(String.fromCharCode(...nonce));
  const expiresAt = Math.floor(Date.now() / 1000) + CHALLENGE_TTL_SEC;

  await c.env.DB
    .prepare(
      `INSERT INTO attest_challenges (uid, nonce, expires_at) VALUES (?, ?, ?)
       ON CONFLICT(uid) DO UPDATE SET nonce = excluded.nonce, expires_at = excluded.expires_at`,
    )
    .bind(user.uid, nonceB64, expiresAt)
    .run();

  return c.json({ challenge: nonceB64, expiresIn: CHALLENGE_TTL_SEC });
});

/**
 * POST /attest/register — verify the attestation object and store the key.
 * Body: { keyId: base64, attestation: base64 }
 */
attestRoutes.post("/attest/register", requireAuth, async (c) => {
  const user = c.get("user");
  const body = await c.req.json<{ keyId?: string; attestation?: string }>();
  if (!body.keyId || !body.attestation) {
    return c.json({ error: "keyId and attestation are required" }, 400);
  }

  const row = await c.env.DB
    .prepare("SELECT nonce, expires_at FROM attest_challenges WHERE uid = ?")
    .bind(user.uid)
    .first<{ nonce: string; expires_at: number }>();
  if (!row || row.expires_at < Math.floor(Date.now() / 1000)) {
    return c.json({ error: "Challenge expired — request a new one" }, 400);
  }

  try {
    const result = await verifyAttestation({
      attestationB64: body.attestation,
      keyIdB64: body.keyId,
      challenge: b64ToBytes(row.nonce),
      appId: APP_ID,
      // Debug builds attest against Apple's development environment. Once
      // the gate ENFORCES, a debug-signed build must not satisfy it.
      allowDevelopment: c.env.ATTEST_MODE !== "enforce",
    });

    await c.env.DB
      .prepare(
        `INSERT INTO attest_keys (uid, key_id, public_key, counter, created_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(key_id) DO UPDATE SET
           uid = excluded.uid, public_key = excluded.public_key,
           counter = excluded.counter`,
      )
      .bind(user.uid, result.keyId, result.publicKeySpki, 0, new Date().toISOString())
      .run();

    // Burn the challenge — single use.
    await c.env.DB
      .prepare("DELETE FROM attest_challenges WHERE uid = ?")
      .bind(user.uid)
      .run();

    return c.json({ registered: true });
  } catch (err) {
    const message = err instanceof Error ? err.message : "verification failed";
    console.error(`attest register failed for ${user.uid}: ${message}`);
    return c.json({ error: `Attestation rejected: ${message}` }, 400);
  }
});

/**
 * Assertion check middleware for privileged routes. Reads headers
 * `X-CaptureCat-Key-Id` + `X-CaptureCat-Assertion` (base64 CBOR assertion over the
 * raw request body). Behavior depends on ATTEST_MODE.
 */
export function checkAssertion() {
  return createMiddleware<{ Bindings: Env; Variables: Variables }>(
    async (c, next) => {
      const mode = c.env.ATTEST_MODE ?? "report";
      if (mode === "off") return next();

      const user = c.get("user");
      const keyId = c.req.header("X-CaptureCat-Key-Id");
      const assertion = c.req.header("X-CaptureCat-Assertion");

      const fail = async (reason: string) => {
        console.warn(`attest[${mode}] uid=${user?.uid ?? "?"}: ${reason}`);
        if (mode !== "enforce") return next();
        // Exemption list for hardware that can't attest (Intel, old macOS).
        if (user) {
          const exempt = await c.env.DB
            .prepare("SELECT uid FROM attest_exemptions WHERE uid = ?")
            .bind(user.uid)
            .first();
          if (exempt) return next();
        }
        return c.json({ error: "Device attestation required" }, 401);
      };

      if (!keyId || !assertion) return fail("missing assertion headers");
      if (!user) return fail("no authenticated user");

      const row = await c.env.DB
        .prepare("SELECT public_key, counter FROM attest_keys WHERE key_id = ? AND uid = ?")
        .bind(keyId, user.uid)
        .first<{ public_key: string; counter: number }>();
      if (!row) return fail("unknown key id");

      try {
        const bodyBytes = new Uint8Array(await c.req.raw.clone().arrayBuffer());
        const { counter } = await verifyAssertion({
          assertionB64: assertion,
          clientData: bodyBytes,
          publicKeySpkiB64: row.public_key,
          appId: APP_ID,
          lastCounter: row.counter,
        });
        await c.env.DB
          .prepare("UPDATE attest_keys SET counter = ? WHERE key_id = ?")
          .bind(counter, keyId)
          .run();
        return next();
      } catch (err) {
        return fail(err instanceof Error ? err.message : "verification error");
      }
    },
  );
}
