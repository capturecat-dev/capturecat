/**
 * Report categories for the share page's "Report video" dialog. Raw values
 * and labels mirror the API's (apps/api/src/lib/moderation.ts REPORT_REASONS
 * / REPORT_REASON_LABELS) — report-reasons.test.ts reads that file — because
 * the API's zod enum is what accepts or refuses them.
 */
export const REPORT_REASONS = [
  { value: "spam", label: "Spam or misleading" },
  { value: "sexual", label: "Sexual content" },
  { value: "violence", label: "Violence or gore" },
  { value: "hate", label: "Hate or harassment of a group" },
  { value: "harassment", label: "Bullying or harassment" },
  { value: "illegal", label: "Illegal activity" },
  { value: "copyright", label: "Copyright infringement" },
  { value: "other", label: "Something else" },
] as const;

export type ReportReason = (typeof REPORT_REASONS)[number]["value"];

export const REPORT_DETAILS_MAX = 1000;

/** What the API says about a video an admin took down (410 body). */
export const REMOVED_FALLBACK_MESSAGE = "This video was removed for violating CaptureCat's terms.";
