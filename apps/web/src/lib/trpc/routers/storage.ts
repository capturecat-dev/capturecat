import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * Bring-your-own S3 bucket for share videos — api.capturecat.so
 * /api/storage/bucket (apps/api/src/routes/storage.ts). The API tests the
 * bucket before saving and never returns the secret; this router only relays.
 */

export const STORAGE_PROVIDERS = ["aws", "r2", "b2", "wasabi", "minio", "other"] as const;
export type StorageProvider = (typeof STORAGE_PROVIDERS)[number];

export type ConnectedBucket = {
  id: string;
  provider: StorageProvider;
  endpoint: string | null;
  region: string;
  bucket: string;
  pathPrefix: string;
  forcePathStyle: boolean;
  publicBaseUrl: string | null;
  accessKeyIdHint: string;
  verifiedAt: string | null;
  videoCount: number;
};

export type BucketState = {
  enabled: boolean;
  available: boolean;
  bucket: ConnectedBucket | null;
  retainedCount: number;
  corsOrigins: string[];
};

async function fail(res: Response, fallback: string): Promise<never> {
  const body = (await res.json().catch(() => ({}))) as { error?: string };
  throw new TRPCError({
    code:
      res.status === 402 || res.status === 403
        ? "FORBIDDEN"
        : res.status === 404
          ? "NOT_FOUND"
          : res.status >= 500
            ? "INTERNAL_SERVER_ERROR"
            : "BAD_REQUEST",
    message: body.error ?? fallback,
  });
}

export const storageRouter = createTRPCRouter({
  bucket: authedProcedure.query(async () => {
    const res = await apiFetch("/api/storage/bucket");
    if (!res.ok) return fail(res, "Could not load storage settings");
    return (await res.json()) as BucketState;
  }),

  connect: authedProcedure
    .input(
      z.object({
        provider: z.enum(STORAGE_PROVIDERS),
        endpoint: z.string().max(300).nullable(),
        region: z.string().max(40),
        bucket: z.string().max(255),
        pathPrefix: z.string().max(200),
        forcePathStyle: z.boolean(),
        publicBaseUrl: z.string().max(500).nullable(),
        accessKeyId: z.string().max(128),
        secretAccessKey: z.string().max(256),
      })
    )
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/storage/bucket", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) return fail(res, "Could not connect the bucket");
      return (await res.json()) as BucketState;
    }),

  disconnect: authedProcedure.mutation(async () => {
    const res = await apiFetch("/api/storage/bucket", { method: "DELETE" });
    if (!res.ok) return fail(res, "Could not disconnect the bucket");
    return (await res.json()) as { disconnected: boolean; retained: boolean; videoCount: number };
  }),

  /** A presigned PUT the BROWSER tries, to learn whether the bucket's CORS
   *  admits this origin (the web recorder uploads straight to the bucket). */
  corsProbe: authedProcedure.mutation(async () => {
    const res = await apiFetch("/api/storage/bucket/cors-probe", { method: "POST" });
    if (!res.ok) return fail(res, "Could not start the browser upload check");
    return (await res.json()) as { uploadUrl: string; contentType: string; body: string };
  }),

  corsProbeDone: authedProcedure.mutation(async () => {
    await apiFetch("/api/storage/bucket/cors-probe", { method: "DELETE" });
    return { ok: true };
  }),
});
