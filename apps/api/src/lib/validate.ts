/**
 * Request-body validation glue for Hono routes.
 *
 * Every JSON body a route reads goes through `parseJsonBody` with a zod
 * schema. The route gets typed, already-normalised data or one error string
 * it can hand straight back as `{ error }` — the shape the desktop app's
 * `AuthService.errorMessage(from:)` reads.
 */

import { z } from "zod";

export type ParsedBody<S extends z.ZodType> =
  | { ok: true; data: z.output<S> }
  | { ok: false; error: string };

/** "fileSizeBytes: Too big" — the first issue, with its path when it has one. */
export function firstIssueMessage(err: z.ZodError): string {
  const issue = err.issues[0];
  if (!issue) return "Invalid request";
  const path = issue.path.map(String).join(".");
  return path ? `${path}: ${issue.message}` : issue.message;
}

export async function parseJsonBody<S extends z.ZodType>(
  req: { json(): Promise<unknown> },
  schema: S,
  options: {
    /** Treat an unparseable/empty body as `{}` (for routes where every field
     *  is optional) instead of a 400. */
    emptyOnInvalidJson?: boolean;
  } = {},
): Promise<ParsedBody<S>> {
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    if (!options.emptyOnInvalidJson) return { ok: false, error: "Request body must be JSON" };
    raw = {};
  }
  return parseValue(raw, schema);
}

export function parseValue<S extends z.ZodType>(raw: unknown, schema: S): ParsedBody<S> {
  const result = schema.safeParse(raw);
  return result.success
    ? { ok: true, data: result.data }
    : { ok: false, error: firstIssueMessage(result.error) };
}
