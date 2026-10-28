/**
 * The crawler policy every CaptureCat robots.txt states: the marketing site
 * (routes/robots[.]txt.ts) and the app host (server/app-host-files.ts). The
 * API Worker's api. and mcp. hosts state the same policy
 * (apps/api src/routes/front-door.ts).
 *
 * Content policy, adjust to taste: search, agent-answering, and training are
 * all allowed. Change `CONTENT_SIGNAL` to flip any of them.
 */
export const CONTENT_SIGNAL = "search=yes, ai-input=yes, ai-train=yes";

/** Explicit groups so each AI crawler sees a rule addressed to it by name. */
export const AI_AGENTS = [
  "GPTBot",
  "OAI-SearchBot",
  "ChatGPT-User",
  "ClaudeBot",
  "Claude-Web",
  "anthropic-ai",
  "Claude-SearchBot",
  "Google-Extended",
  "PerplexityBot",
  "CCBot",
  "Applebot-Extended",
  "Meta-ExternalAgent",
];

/** One robots.txt group: the agent, its content signal, then the rules. */
export function robotsGroup(agent: string, rules: string[]): string {
  return [`User-agent: ${agent}`, `Content-Signal: ${CONTENT_SIGNAL}`, ...rules].join("\n");
}
