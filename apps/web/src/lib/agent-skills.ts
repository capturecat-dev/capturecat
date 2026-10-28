/**
 * Agent Skills published at /.well-known/agent-skills/ (Agent Skills
 * Discovery RFC v0.2.0, https://github.com/cloudflare/agent-skills-discovery-rfc).
 *
 * Each skill is one SKILL.md (agentskills.io format: YAML front matter with
 * `name` and `description`, then Markdown). The discovery index in
 * src/server/agent-discovery.ts lists them with a sha256 digest computed from
 * these exact bytes, so the digest can never disagree with what is served.
 *
 * Facts here mirror the /agents page (site-content.ts) and the API routes
 * (apps/api/src/routes/screenshot.ts, apps/api/src/mcp/); change them together.
 */
import { SITE_URL } from "./site-url";
import { SCREENSHOT_API_SKILL } from "./screenshot-api-skill";
import { REMOTE_MCP_SKILL } from "./remote-mcp-skill";

export interface AgentSkill {
  /** Lowercase alphanumeric + hyphens (the RFC's name rule). */
  name: string;
  description: string;
  markdown: string;
}

const MCP_SKILL: AgentSkill = {
  name: "capturecat-mcp",
  description:
    "Record, inspect, edit and export Mac screen recordings by driving the CaptureCat app through its built-in MCP server.",
  markdown: `---
name: capturecat-mcp
description: Record, inspect, edit and export Mac screen recordings by driving the CaptureCat app through its built-in MCP server.
---

# CaptureCat MCP server

## When to use this

Use it when the user wants a screen recording made or polished on their Mac:
record a demo or bug report, tighten pacing, add zooms, blur secrets, add
captions or annotations, restyle the frame, cut a vertical clip, or export an
MP4/MOV. It edits real CaptureCat projects with the same engine as the app's
editor, so what the agent sees in \`render_frames\` is what the export contains.

Do not use it for: non-Mac machines (use the browser editor at
https://app.capturecat.so instead), or anything that needs a server-side
recording API — this server runs locally inside the Mac app. A cloud agent
that only needs the user's shared videos, comments and analytics should use
the remote server (\`capturecat-remote\`, https://mcp.capturecat.so/mcp).

## Connect

The server ships inside the app binary and speaks MCP over stdio:

\`\`\`sh
# Claude Code
claude mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp

# OpenAI Codex
codex mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp
\`\`\`

Other clients (Claude Desktop, Cursor, GitHub Copilot, Windsurf): add a
\`capturecat\` server whose \`command\` is that binary with \`args: ["--mcp"]\`.
Or, in the app: menu bar icon → Connect AI Agents. Install the app from
${SITE_URL}/download.

## How to work

1. Read the editing playbook the server sends on connect (its instructions).
2. Find the project: \`list_projects\` or \`search_captures\`; record a new one
   with \`list_capture_targets\` → \`start_recording\` → \`stop_recording\`.
3. Inspect: \`describe_project\` (timeline, click clusters, idle spans, quiet
   stretches) and \`get_transcript\`.
4. Edit: prefer one \`apply_edits\` plan (all-or-nothing). Single-purpose tools
   exist too: \`auto_zoom\`, \`add_effect\`, \`add_annotation\`, \`add_blur\`,
   \`set_speed\`, \`set_trim\`, \`cut_video\`, \`set_style\`, \`style_options\`.
5. Check your work with \`render_frames\` (frames or a labelled contact sheet).
6. \`export_project\` when it looks right. \`undo\` reverts the last agent edits
   (the last 30 are kept).

Edits are written atomically with a backup; media files are never modified.
An invalid edit is refused with a readable error — fix the input and retry.
If the project is open with unsaved in-app changes, those win: ask the user to
save first.

More: ${SITE_URL}/agents.md
`,
};

export const AGENT_SKILLS: AgentSkill[] = [MCP_SKILL, REMOTE_MCP_SKILL, SCREENSHOT_API_SKILL];

/** Where a skill's SKILL.md is served. */
export function skillPath(name: string): string {
  return `/.well-known/agent-skills/${name}/SKILL.md`;
}
