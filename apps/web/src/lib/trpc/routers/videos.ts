import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * Videos, served entirely by api.capturecat.so.
 *
 * This router used to read Firestore directly — which had silently stopped
 * returning anything, because uploads have written D1 since the API replaced
 * its Firestore client. The dashboard was listing a frozen collection.
 *
 * NOTE ON THE DELETE STEP-UP, deliberately not reimplemented here.
 * The Firebase version required the browser to force-refresh an ID token and
 * re-verified it server-side, so a stolen long-lived session cookie alone could
 * not delete media. Better Auth has no ID-token concept and `session.freshAge`
 * is not configured on the API, so that proof-of-liveness is GONE. It is a real
 * reduction in blast-radius protection, not an oversight — restoring it means
 * either configuring session freshness on the API (which also changes desktop
 * session semantics) or minting a short-TTL delete-confirm token.
 */
export const videosRouter = createTRPCRouter({
  list: authedProcedure.query(async () => {
    const res = await apiFetch("/api/videos");
    if (!res.ok) {
      throw new TRPCError({
        code: res.status === 403 ? "FORBIDDEN" : "INTERNAL_SERVER_ERROR",
        message: "Could not load your videos",
      });
    }
    return (await res.json()) as {
      videos: Array<{
        videoId: string;
        orgId: string | null;
        fileName: string;
        contentType: string;
        fileSizeBytes: number;
        durationSeconds: number;
        isPrivate: boolean;
        createdAt: string;
        url: string;
        projectId: string | null;
        allowDownload: boolean;
        hasPassword: boolean;
        expiresAt: string | null;
        maxViews: number | null;
        brandAccent: string | null;
        commentsEnabled: boolean;
        currentVersion: number;
        showVersionHistory: boolean;
        ctaLabel: string | null;
        ctaUrl: string | null;
        profileVisible: boolean;
        thumbnailType: string | null;
        thumbnailUrl: string | null;
      }>;
      // Reported by the API from PRO_PLAN_LIMITS so the dashboard stops
      // hardcoding a limit that could drift from the one uploads enforce.
      storageUsedBytes: number;
      storageLimitBytes: number;
    };
  }),

  /** Owner share-page controls: download button, password, expiry, view cap,
   *  brand accent. Password travels once, over TLS, and is stored hashed. */
  updateSettings: authedProcedure
    .input(
      z.object({
        videoId: z.string().min(1),
        allowDownload: z.boolean().optional(),
        password: z.string().min(1).max(100).nullable().optional(),
        expiresAt: z.string().nullable().optional(),
        maxViews: z.number().int().min(0).nullable().optional(),
        brandAccent: z.string().regex(/^#[0-9a-fA-F]{6}$/).nullable().optional(),
        showVersionHistory: z.boolean().optional(),
        ctaLabel: z.string().min(1).max(60).nullable().optional(),
        ctaUrl: z.string().url().startsWith("https://").max(300).nullable().optional(),
        profileVisible: z.boolean().optional(),
      })
    )
    .mutation(async ({ input }) => {
      const { videoId, ...patch } = input;
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(videoId)}/settings`,
        {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(patch),
        }
      );
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "INTERNAL_SERVER_ERROR",
          message: "Could not update share settings",
        });
      }
      return (await res.json()) as { videoId: string; updated: string[] };
    }),

  /** Remove the custom thumbnail — back to the decoded-frame fallback.
   *  (Uploads go browser → API directly; see src/lib/thumbnails.ts — binary
   *  bodies don't belong in a superjson tRPC payload.) */
  deleteThumbnail: authedProcedure
    .input(z.object({ videoId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(input.videoId)}/thumbnail`,
        { method: "DELETE" }
      );
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "NOT_FOUND",
          message: "Could not remove thumbnail",
        });
      }
      return { ok: true };
    }),

  /** Version history of one video (replace-in-place uploads). Owner only. */
  versions: authedProcedure
    .input(z.object({ videoId: z.string().min(1) }))
    .query(async ({ input }) => {
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(input.videoId)}/versions`
      );
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "NOT_FOUND",
          message: "Could not load version history",
        });
      }
      return (await res.json()) as {
        videoId: string;
        currentVersion: number;
        showVersionHistory: boolean;
        versions: Array<{
          version: number;
          fileSizeBytes: number;
          durationSeconds: number;
          status: "pending" | "ready";
          createdAt: string;
          current: boolean;
        }>;
      };
    }),

  /** Point the share link back at an older version. */
  restoreVersion: authedProcedure
    .input(z.object({ videoId: z.string().min(1), version: z.number().int().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(input.videoId)}/versions/${input.version}/restore`,
        { method: "POST" }
      );
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as { error?: string };
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "NOT_FOUND",
          message: body.error ?? "Could not restore version",
        });
      }
      return (await res.json()) as { videoId: string; currentVersion: number };
    }),

  /** Delete one historical version's file (the live version is protected). */
  deleteVersion: authedProcedure
    .input(z.object({ videoId: z.string().min(1), version: z.number().int().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(input.videoId)}/versions/${input.version}`,
        { method: "DELETE" }
      );
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as { error?: string };
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "BAD_REQUEST",
          message: body.error ?? "Could not delete version",
        });
      }
      return { ok: true };
    }),

  /** Dashboard playlists: emoji-labelled collections for organizing the
   *  library. Membership comes back as videoIds so the client filters its
   *  already-loaded list. */
  playlists: authedProcedure.query(async () => {
    const res = await apiFetch("/api/playlists");
    if (!res.ok) {
      throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "Could not load playlists" });
    }
    return (await res.json()) as {
      playlists: Array<{
        playlistId: string;
        name: string;
        emoji: string | null;
        videoIds: string[];
        createdAt: string;
      }>;
    };
  }),

  createPlaylist: authedProcedure
    .input(z.object({ name: z.string().min(1).max(60), emoji: z.string().max(16).optional() }))
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/playlists", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as { error?: string };
        throw new TRPCError({ code: "BAD_REQUEST", message: body.error ?? "Could not create playlist" });
      }
      return (await res.json()) as { playlistId: string; name: string; emoji: string | null };
    }),

  deletePlaylist: authedProcedure
    .input(z.object({ playlistId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/playlists/${encodeURIComponent(input.playlistId)}`, {
        method: "DELETE",
      });
      if (!res.ok) {
        throw new TRPCError({ code: "NOT_FOUND", message: "Could not delete playlist" });
      }
      return { ok: true };
    }),

  addToPlaylist: authedProcedure
    .input(z.object({ playlistId: z.string().min(1), videoId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/playlists/${encodeURIComponent(input.playlistId)}/videos`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ videoId: input.videoId }),
        }
      );
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as { error?: string };
        throw new TRPCError({ code: "BAD_REQUEST", message: body.error ?? "Could not add to playlist" });
      }
      return { ok: true };
    }),

  removeFromPlaylist: authedProcedure
    .input(z.object({ playlistId: z.string().min(1), videoId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/playlists/${encodeURIComponent(input.playlistId)}/videos/${encodeURIComponent(input.videoId)}`,
        { method: "DELETE" }
      );
      if (!res.ok) {
        throw new TRPCError({ code: "NOT_FOUND", message: "Could not remove from playlist" });
      }
      return { ok: true };
    }),

  /** Background share-upload jobs from the desktop app (ShareJobs Durable
   *  Object) — lets the dashboard show an upload's progress live while the
   *  Mac is still streaming the file to R2. */
  uploadJobs: authedProcedure.query(async () => {
    const res = await apiFetch("/api/upload/jobs");
    if (!res.ok) {
      throw new TRPCError({
        code: "INTERNAL_SERVER_ERROR",
        message: "Could not load upload jobs",
      });
    }
    return (await res.json()) as {
      jobs: Array<{
        jobId: string;
        videoId: string;
        projectId: string | null;
        projectName: string | null;
        fileName: string;
        fileSizeBytes: number;
        state: "uploading" | "completing" | "done" | "failed";
        progress: number;
        shareUrl: string | null;
        error: string | null;
        createdAt: number;
        updatedAt: number;
      }>;
    };
  }),

  /** Server-side Gemini title/summary/chapters (Pro-gated on the API). */
  generateAiSummary: authedProcedure
    .input(z.object({ videoId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(input.videoId)}/ai-summary`,
        { method: "POST" }
      );
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as { error?: string };
        throw new TRPCError({
          code: res.status === 402 ? "FORBIDDEN" : "INTERNAL_SERVER_ERROR",
          message: body.error ?? "Could not generate AI summary",
        });
      }
      return (await res.json()) as {
        title: string | null;
        summary: string | null;
        chapters: Array<{ start: number; label: string }>;
      };
    }),

  /** Library-wide transcript search. */
  transcriptSearch: authedProcedure
    .input(z.object({ q: z.string() }))
    .query(async ({ input }) => {
      if (input.q.trim().length < 2) return { results: [] };
      const res = await apiFetch(
        `/api/transcripts/search?q=${encodeURIComponent(input.q.trim())}`
      );
      if (!res.ok) return { results: [] };
      return (await res.json()) as {
        results: Array<{
          videoId: string;
          segments: Array<{ start: number; end: number; text: string }>;
        }>;
      };
    }),

  /** Custom share domains (Pro-gated on the API). */
  domains: authedProcedure.query(async () => {
    const res = await apiFetch("/api/domains");
    if (!res.ok) {
      throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "Could not load domains" });
    }
    return (await res.json()) as {
      enabled: boolean;
      cnameTarget: string;
      domains: Array<{ domain: string; verified: boolean; createdAt: string }>;
    };
  }),

  addDomain: authedProcedure
    .input(z.object({ domain: z.string().min(3).max(253) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/domains", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ domain: input.domain }),
      });
      const body = (await res.json().catch(() => ({}))) as { error?: string };
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 402 ? "FORBIDDEN" : "BAD_REQUEST",
          message: body.error ?? "Could not add domain",
        });
      }
      return body as unknown as { domain: string; verified: boolean; cnameTarget: string };
    }),

  verifyDomain: authedProcedure
    .input(z.object({ domain: z.string() }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/domains/${encodeURIComponent(input.domain)}/verify`,
        { method: "POST" }
      );
      if (!res.ok) {
        throw new TRPCError({ code: "NOT_FOUND", message: "Could not verify domain" });
      }
      return (await res.json()) as {
        domain: string;
        verified: boolean;
        found: string[];
        expected: string;
      };
    }),

  removeDomain: authedProcedure
    .input(z.object({ domain: z.string() }))
    .mutation(async ({ input }) => {
      await apiFetch(`/api/domains/${encodeURIComponent(input.domain)}`, {
        method: "DELETE",
      });
      return { ok: true };
    }),

  analytics: authedProcedure
    .input(z.object({ videoId: z.string().min(1) }))
    .query(async ({ input }) => {
      const res = await apiFetch(
        `/api/video/${encodeURIComponent(input.videoId)}/analytics`
      );
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "NOT_FOUND",
          message: "Could not load analytics",
        });
      }
      return (await res.json()) as {
        videoId: string;
        projectId: string | null;
        durationSeconds: number;
        views: number;
        plays: number;
        completions: number;
        ctaClicks: number;
        ctaLabel: string | null;
        ctaUrl: string | null;
        avgWatchedSeconds: number;
        watchHeatmap: Array<{ second: number; viewers: number }>;
        dropOff: Array<{ second: number; sessions: number }>;
        clicks: Array<{ second: number; count: number }>;
        countries: Array<{ country: string; count: number }>;
        referrers: Array<{ referrer: string; count: number }>;
        comments: Array<{
          commentId: string;
          authorName: string;
          body: string;
          videoTime: number;
          createdAt: string;
        }>;
      };
    }),

  setPrivacy: authedProcedure
    .input(z.object({ videoId: z.string().min(1), isPrivate: z.boolean() }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/video/${encodeURIComponent(input.videoId)}/privacy`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ isPrivate: input.isPrivate }),
      });
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "NOT_FOUND",
          message: "Could not update privacy",
        });
      }
      return { ok: true };
    }),

  delete: authedProcedure
    .input(z.object({ videoId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/video/${encodeURIComponent(input.videoId)}`, {
        method: "DELETE",
      });
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 403 ? "FORBIDDEN" : "NOT_FOUND",
          message: "Could not delete video",
        });
      }
      return { ok: true };
    }),
});
