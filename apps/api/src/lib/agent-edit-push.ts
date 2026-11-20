/**
 * "AI finished editing …" — an APNs alert to the project owner's iPhones and
 * iPads after an agent saves one of their cloud projects through the remote
 * MCP server (src/mcp/project-tools.ts: apply_edits and the single-op tools,
 * restore_version).
 *
 * FINISHED, not "started": an agent usually saves several times in a row
 * (one apply_edits, a look at render_frames, a fix). Every save schedules a
 * check `AGENT_EDIT_PUSH_DELAY_MS` later (ctx.waitUntil — a Worker may keep
 * working ~30 s after its response); the check pushes only when the project's
 * head is STILL the revision that save wrote, so a burst of edits is one
 * notification, sent once the agent went quiet. `apns-collapse-id` per
 * project folds any stragglers on the device too.
 *
 * Quiet by construction: no APNs secrets (apnsConfig → null) = no push; a
 * device without a token is skipped; a dead token is forgotten exactly like
 * routes/devices.ts forgets it. Never throws — a failed notification must not
 * fail (or slow) the agent's edit.
 *
 * Payload (the iOS app's PushRouter reads `cc`):
 *   aps.alert   { title: "AI finished editing", body: "Claude edited “Demo”." }
 *   aps.thread-id "agent-edit-<projectId>"
 *   cc          { type: "agentEdited", projectId, revision, agentName, projectName }
 */

import type { Env } from "../types";
import { apnsConfig, sendApnsAlert, type ApnsConfig, type ApnsEnvironment } from "./apns";
import { cleanLabel } from "./comments";

/** How long an agent must stay quiet on a project before the push goes out. */
export const AGENT_EDIT_PUSH_DELAY_MS = 15_000;
/** A push nobody saw within an hour is stale news. */
const AGENT_EDIT_PUSH_TTL_SEC = 3600;
const NAME_MAX = 60;
const PROJECT_NAME_MAX = 80;

export interface AgentEditPushInput {
  ownerUid: string;
  projectId: string;
  projectName: string;
  /** The token's name — an OAuth client's own name ("Claude"), or what the user called a personal token. */
  agentName: string;
  /** The revision this save wrote. */
  revision: number;
}

/** One line of user-visible text: no controls or bidi overrides, clipped. */
function display(value: string, max: number, fallback: string): string {
  const clipped = Array.from(cleanLabel(value)).slice(0, max).join("").trim();
  return clipped === "" ? fallback : clipped;
}

export function agentEditPayload(input: AgentEditPushInput): Record<string, unknown> {
  const agentName = display(input.agentName, NAME_MAX, "Your AI agent");
  const projectName = display(input.projectName, PROJECT_NAME_MAX, "a project");
  return {
    aps: {
      alert: { title: "AI finished editing", body: `${agentName} edited “${projectName}”.` },
      sound: "default",
      "thread-id": `agent-edit-${input.projectId}`,
    },
    cc: { type: "agentEdited", projectId: input.projectId, revision: input.revision, agentName, projectName },
  };
}

interface DeviceTokenRow {
  device_id: string;
  apns_token: string;
  apns_env: string;
}

/** Sends now (no debounce). Returns how many devices accepted it. */
export async function sendAgentEditPush(env: Env, input: AgentEditPushInput, config: ApnsConfig | null = apnsConfig(env)): Promise<number> {
  if (!config) return 0;
  const { results } = await env.DB.prepare(
    `SELECT device_id, apns_token, apns_env FROM user_devices
      WHERE user_id = ?1 AND platform = 'ios' AND apns_token IS NOT NULL AND apns_env IS NOT NULL`,
  )
    .bind(input.ownerUid)
    .all<DeviceTokenRow>();
  let sent = 0;
  const payload = agentEditPayload(input);
  for (const row of results ?? []) {
    if (row.apns_env !== "sandbox" && row.apns_env !== "production") continue;
    const result = await sendApnsAlert(config, {
      deviceToken: row.apns_token,
      environment: row.apns_env as ApnsEnvironment,
      pushType: "alert",
      priority: 10,
      expiration: Math.floor(Date.now() / 1000) + AGENT_EDIT_PUSH_TTL_SEC,
      collapseId: `agent-edit-${input.projectId}`,
      payload,
    });
    if (result.ok) {
      sent += 1;
    } else if (result.kind === "dead_token") {
      // Only the token we just used: a fresh registration that raced this push survives.
      await env.DB.prepare(
        `UPDATE user_devices SET apns_token = NULL, apns_env = NULL, updated_at = ?1
          WHERE user_id = ?2 AND device_id = ?3 AND apns_token = ?4`,
      )
        .bind(new Date().toISOString(), input.ownerUid, row.device_id, row.apns_token)
        .run();
    }
  }
  return sent;
}

/**
 * Debounced: waits `delayMs`, then pushes only if the project's head is still
 * `input.revision` (nobody — this agent included — saved since). Hand the
 * returned promise to ctx.waitUntil. Never rejects.
 */
export async function agentEditPushAfterQuiet(
  env: Env,
  input: AgentEditPushInput,
  delayMs: number = agentEditPushDelay(env),
): Promise<void> {
  try {
    const config = apnsConfig(env);
    if (!config) return;
    if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
    const head = await env.DB.prepare(`SELECT revision FROM cloud_projects WHERE id = ?1 AND owner_uid = ?2`)
      .bind(input.projectId, input.ownerUid)
      .first<{ revision: number }>();
    if (!head || head.revision !== input.revision) return;
    await sendAgentEditPush(env, input, config);
  } catch (err) {
    console.error("agent-edit push failed", err instanceof Error ? err.message : err);
  }
}

/** AGENT_EDIT_PUSH_DELAY_MS, overridable by the `AGENT_EDIT_PUSH_DELAY_MS` var (local test servers). */
export function agentEditPushDelay(env: Env): number {
  const raw = Number((env as { AGENT_EDIT_PUSH_DELAY_MS?: string }).AGENT_EDIT_PUSH_DELAY_MS);
  return Number.isFinite(raw) && raw >= 0 ? Math.min(raw, 25_000) : AGENT_EDIT_PUSH_DELAY_MS;
}
