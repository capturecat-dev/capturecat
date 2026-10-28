/**
 * WebMCP for the admin console: read-only tools over the same tRPC queries
 * the pages use, so a browser agent working for an admin can answer "where
 * did sign-ups come from this week?" or "what does this user store?".
 *
 * Mirrors apps/web/src/lib/webmcp.ts (a separate package, so the ~40-line
 * registration helper is repeated rather than shared): `document.modelContext`
 * first, the deprecated `navigator.modelContext` as a fallback, JSON results,
 * an actionable `ERROR:` line on failure. Nothing here writes: tester/blocked
 * flags and plans stay human-only.
 */
import type { Analytics, UserActivity } from "@/lib/analytics-types";

type ToolArgs = Record<string, unknown>;

interface ModelContextLike {
  registerTool(
    tool: {
      name: string;
      title?: string;
      description: string;
      inputSchema: object;
      execute: (input: ToolArgs, options: { signal: AbortSignal }) => Promise<string>;
      annotations?: { readOnlyHint?: boolean; consequentialHint?: boolean };
    },
    options?: { signal?: AbortSignal },
  ): Promise<void> | void;
}

export function findModelContext(scope: { document?: unknown; navigator?: unknown } = globalThis as never): ModelContextLike | null {
  const fromDocument = (scope.document as { modelContext?: ModelContextLike } | undefined)?.modelContext;
  if (fromDocument && typeof fromDocument.registerTool === "function") return fromDocument;
  const legacy = (scope.navigator as { modelContext?: ModelContextLike } | undefined)?.modelContext;
  if (legacy && typeof legacy.registerTool === "function") return legacy;
  return null;
}

export interface AdminTool {
  name: string;
  title: string;
  description: string;
  inputSchema: { type: "object"; properties: Record<string, unknown>; required: string[]; additionalProperties: false };
  execute: (input: ToolArgs) => Promise<unknown>;
}

export interface AdminUserRow {
  id: string;
  email: string;
  name: string | null;
  createdAt: string;
  tier: string;
  role: string;
  providers: string[];
  signup: { country: string | null; via: string | null; source: { label: string } | null };
  usage: { storageBytes: number; videos: number; projects: number; lastActive: string | null } | null;
}

export interface AdminDeps {
  analytics: (days: 7 | 30 | 90 | 365) => Promise<Analytics>;
  listUsers: () => Promise<{ users: AdminUserRow[] }>;
  userActivity: (userId: string) => Promise<UserActivity>;
}

const DAYS = [7, 30, 90, 365] as const;
const SORTS = ["newest", "storage", "active"] as const;

export function adminTools(deps: AdminDeps): AdminTool[] {
  return [
    {
      name: "get_admin_analytics",
      title: "CaptureCat analytics",
      description:
        "The admin Analytics page as JSON for a date range: totals (users, active, paid, visits, downloads, " +
        "sign-ups, shares), sources with the pages each lands people on, countries, landing pages, devices, " +
        "feature adoption, storage by kind and the top users by storage.",
      inputSchema: {
        type: "object",
        properties: { days: { type: "integer", enum: [...DAYS], default: 30, description: "Range in days." } },
        required: [],
        additionalProperties: false,
      },
      execute: async (input) => {
        const days = input.days === undefined ? 30 : Number(input.days);
        if (!(DAYS as readonly number[]).includes(days)) throw new Error("`days` must be 7, 30, 90 or 365.");
        return deps.analytics(days as (typeof DAYS)[number]);
      },
    },
    {
      name: "list_admin_users",
      title: "List CaptureCat users",
      description:
        "Users with tier, sign-up source and country, bytes stored, shared videos, cloud projects and last activity. " +
        "Sort by newest, most storage, or most recently active.",
      inputSchema: {
        type: "object",
        properties: {
          sort: { type: "string", enum: [...SORTS], default: "newest", description: "Ordering." },
          limit: { type: "integer", minimum: 1, maximum: 500, default: 50, description: "Maximum users." },
        },
        required: [],
        additionalProperties: false,
      },
      execute: async (input) => {
        const sort = input.sort === undefined ? "newest" : String(input.sort);
        if (!(SORTS as readonly string[]).includes(sort)) throw new Error("`sort` must be newest, storage or active.");
        const limit = Math.min(500, Math.max(1, Number(input.limit) || 50));
        const { users } = await deps.listUsers();
        const sorted = [...users].sort((a, b) =>
          sort === "storage"
            ? (b.usage?.storageBytes ?? 0) - (a.usage?.storageBytes ?? 0)
            : sort === "active"
              ? (b.usage?.lastActive ?? "").localeCompare(a.usage?.lastActive ?? "")
              : b.createdAt.localeCompare(a.createdAt),
        );
        return {
          total: users.length,
          users: sorted.slice(0, limit).map((u) => ({
            id: u.id,
            email: u.email,
            name: u.name,
            tier: u.tier,
            role: u.role,
            createdAt: u.createdAt,
            signsInWith: u.providers,
            source: u.signup.source?.label ?? (u.signup.via === "desktop" ? "Mac app" : null),
            country: u.signup.country,
            storageBytes: u.usage?.storageBytes ?? 0,
            videos: u.usage?.videos ?? 0,
            projects: u.usage?.projects ?? 0,
            lastActive: u.usage?.lastActive ?? null,
          })),
        };
      },
    },
    {
      name: "get_user_activity",
      title: "One user's footprint",
      description:
        "Everything about one user: sign-up source, storage by kind, shared videos with views and comments, cloud " +
        "projects, screenshots, editing sessions and devices.",
      inputSchema: {
        type: "object",
        properties: { userId: { type: "string", description: "A user id from list_admin_users." } },
        required: ["userId"],
        additionalProperties: false,
      },
      execute: async (input) => {
        const userId = typeof input.userId === "string" ? input.userId.trim() : "";
        if (!userId) throw new Error("`userId` is required.");
        return deps.userActivity(userId);
      },
    },
  ];
}

/** Register the admin tools (all read-only). Returns an unregister function. */
export function registerAdminTools(tools: AdminTool[], context: ModelContextLike | null = findModelContext()): () => void {
  if (!context) return () => {};
  const controller = new AbortController();
  for (const tool of tools) {
    void Promise.resolve(
      context.registerTool(
        {
          name: tool.name,
          title: tool.title,
          description: tool.description,
          inputSchema: tool.inputSchema,
          annotations: { readOnlyHint: true, consequentialHint: false },
          execute: async (input) => {
            try {
              return JSON.stringify((await tool.execute(input ?? {})) ?? null);
            } catch (error) {
              return `ERROR: ${error instanceof Error ? error.message : String(error)}`;
            }
          },
        },
        { signal: controller.signal },
      ),
    ).catch(() => {});
  }
  return () => controller.abort();
}
