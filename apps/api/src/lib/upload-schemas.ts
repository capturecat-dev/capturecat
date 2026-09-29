/**
 * Request bodies for the upload routes, as zod schemas.
 *
 * Two validation postures, chosen per field:
 *
 *   • Scalars (fileName, fileSizeBytes, contentType, …) are STRICT: a wrong
 *     type or an out-of-range value is a 400. There is no sensible default
 *     for a mistyped file size.
 *   • Lists of user-authored items (markers, transcript segments, chapters)
 *     are LENIENT per item: each item is validated on its own and dropped if
 *     it fails, so one bad marker, or a marker kind this Worker predates, never
 *     costs the whole share. Nothing is ever stored verbatim — every item is
 *     re-serialised from the parsed shape.
 *
 * Plan limits are NOT here. Size/duration/storage caps come from the plan row
 * (`lib/upload-policy.ts`); this file only proves the body is well-formed.
 */

import { z } from "zod";

/** Hard ceiling on the size a presigned PUT can be signed for, independent of
 *  any plan. Keeps a mis-edited plan row from signing a multi-terabyte PUT. */
export const MAX_SIGNABLE_UPLOAD_BYTES = 5 * 1024 * 1024 * 1024;

export const ALLOWED_CONTENT_TYPES = ["video/mp4", "video/quicktime", "video/webm"] as const;
export type UploadContentType = (typeof ALLOWED_CONTENT_TYPES)[number];

const round3 = (n: number) => Math.round(n * 1000) / 1000;
const round2 = (n: number) => Math.round(n * 100) / 100;

/** Accepts each item independently; the failures fall out, and the cap
 *  applies to what survived so a bad item never costs a good one its slot. */
function lenientList<S extends z.ZodType>(item: S, max: number) {
  return z.array(z.unknown()).transform((items) =>
    items
      .flatMap((raw): z.output<S>[] => {
        const r = item.safeParse(raw);
        return r.success ? [r.data] : [];
      })
      .slice(0, max),
  );
}

// --- Share-page markers -----------------------------------------------------

export interface Marker {
  start: number;
  end: number;
  label?: string;
  autoPause?: boolean;
  pauseDuration?: number;
}

const MarkerSchema = z
  .object({
    start: z.number().transform((v) => Math.max(0, v)),
    end: z.number().transform((v) => Math.max(0, v)),
    label: z.unknown().optional(),
    autoPause: z.unknown().optional(),
    pauseDuration: z.unknown().optional(),
  })
  .refine((m) => m.end >= m.start)
  .transform((m): Marker => {
    const out: Marker = { start: round3(m.start), end: round3(m.end) };
    if (typeof m.label === "string" && m.label.trim()) {
      out.label = m.label.trim().slice(0, 120);
    }
    if (m.autoPause === true) {
      out.autoPause = true;
      const d = typeof m.pauseDuration === "number" && Number.isFinite(m.pauseDuration) ? m.pauseDuration : 2;
      out.pauseDuration = Math.min(30, Math.max(0.5, d));
    }
    return out;
  });

/** Serialised marker list for the `annotations_json` column, or null when
 *  nothing survived. */
export const MarkersSchema = lenientList(MarkerSchema, 100).transform((markers) =>
  markers.length > 0 ? JSON.stringify(markers) : null,
);

// --- Transcript -------------------------------------------------------------

export interface TranscriptWord {
  start: number;
  end: number;
  text: string;
}
export interface TranscriptSegmentInput {
  start: number;
  end: number;
  text: string;
  words?: TranscriptWord[];
}

const WordSchema = z
  .object({ start: z.number(), end: z.number(), text: z.string() })
  .transform((w) => ({ start: w.start, end: w.end, text: w.text.trim().slice(0, 80) }))
  // `<=` not `<`: zero-duration words make karaoke progress
  // (t - start) / (end - start) divide by zero downstream.
  .refine((w) => w.end > w.start && w.text.length > 0)
  .transform((w): TranscriptWord => ({ start: round2(w.start), end: round2(w.end), text: w.text }));

const SegmentSchema = z
  .object({
    start: z.number(),
    end: z.number(),
    text: z.string(),
    words: z.unknown().optional(),
  })
  .transform((s) => ({ ...s, text: s.text.trim().slice(0, 500) }))
  .refine((s) => s.end >= s.start && s.text.length > 0)
  .transform((s): TranscriptSegmentInput => {
    const out: TranscriptSegmentInput = { start: round2(s.start), end: round2(s.end), text: s.text };
    if (Array.isArray(s.words)) {
      const words = lenientList(WordSchema, 60).parse(s.words);
      if (words.length > 0) out.words = words;
    }
    return out;
  });

export const TranscriptSchema = lenientList(SegmentSchema, 5000);

// --- Chapters ---------------------------------------------------------------

const ChapterSchema = z
  .object({ start: z.number(), label: z.string() })
  .transform((ch) => ({ start: Math.max(0, ch.start), label: ch.label.slice(0, 60) }));

export const ChaptersSchema = lenientList(ChapterSchema, 12);

// --- Scalars ----------------------------------------------------------------

/** Empty/absent means mp4 — the desktop app has always sent it that way. */
const ContentTypeSchema = z.preprocess(
  (v) => (v === undefined || v === null || v === "" ? "video/mp4" : v),
  z.enum(ALLOWED_CONTENT_TYPES, { error: "Invalid content type" }),
);

const FileSizeSchema = z
  .int({ error: "must be a positive integer" })
  .positive({ error: "must be a positive integer" })
  .max(MAX_SIGNABLE_UPLOAD_BYTES, { error: "must be ≤ 5 GB" });

const DurationSchema = z.number().min(0, { error: "must be ≥ 0" });

/** Bounded, trimmed, and empty → null so the DB never stores "". */
const boundedText = (max: number) =>
  z
    .string()
    .optional()
    .transform((s) => {
      const t = s?.trim().slice(0, max) ?? "";
      return t.length > 0 ? t : null;
    });

/** The editor project this export came from, so the dashboard can deep-link
 *  back into the app. Strictly a UUID or dropped — never stored verbatim. */
const ProjectIdSchema = z
  .string()
  .regex(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/)
  .transform((s): string | null => s.toUpperCase())
  .catch(null);

// --- Bodies -----------------------------------------------------------------

/** POST /upload/video */
export const UploadVideoBodySchema = z.object({
  // Echoed into /meta, Content-Disposition and page titles — bound it.
  fileName: z
    .string({ error: "fileName is required" })
    .trim()
    .min(1, { error: "fileName is required" })
    .transform((s) => s.slice(0, 200)),
  contentType: ContentTypeSchema,
  fileSizeBytes: FileSizeSchema,
  durationSeconds: DurationSchema.default(0),
  commentsEnabled: z.boolean().default(false),
  annotations: MarkersSchema.default(null),
  projectId: ProjectIdSchema,
  transcript: TranscriptSchema.optional(),
  aiTitle: boundedText(80),
  aiSummary: boundedText(600),
  aiChapters: ChaptersSchema.default([]),
});
export type UploadVideoBody = z.output<typeof UploadVideoBodySchema>;

/** POST /upload/video/:videoId/replace — the new cut's metadata lands at
 *  complete time, so only the bytes matter here. `durationSeconds` stays
 *  optional: absent means "keep the current version's". */
export const ReplaceVideoBodySchema = z.object({
  contentType: ContentTypeSchema,
  fileSizeBytes: FileSizeSchema,
  durationSeconds: DurationSchema.optional(),
});
export type ReplaceVideoBody = z.output<typeof ReplaceVideoBodySchema>;

/** POST /upload/video/:videoId/replace/:version/complete */
export const ReplaceCompleteBodySchema = z.object({
  annotations: MarkersSchema.optional(),
  transcript: TranscriptSchema.optional(),
  aiTitle: boundedText(80),
  aiSummary: boundedText(600),
  aiChapters: ChaptersSchema.default([]),
});
export type ReplaceCompleteBody = z.output<typeof ReplaceCompleteBodySchema>;
