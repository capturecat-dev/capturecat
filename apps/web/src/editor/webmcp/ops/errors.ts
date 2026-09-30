/**
 * `MCPServer.ToolError` — an actionable, agent-facing failure. The message is
 * the exact text the Mac server puts after `ERROR: ` (register.ts adds the
 * prefix), so a browser agent and a desktop agent read the same words.
 */
export class ToolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ToolError";
  }
}

/** `error.localizedDescription` for anything a core can throw. */
export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
