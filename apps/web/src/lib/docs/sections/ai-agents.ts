import type { DocSection } from "../types";

/**
 * Checked against apps/macos/CaptureCat/Services/MCPServer.swift (transport,
 * dispatch, history limit), MCPServer+Catalog.swift (tool list, prompts,
 * instructions), MCPServer+Edits.swift (speed range, annotation types),
 * AgentSetup.swift and Views/AppKitSurfaces/AgentSetupWindowController.swift
 * (Connect AI Agents window), StatusMenuBuilder.swift and
 * SettingsWindowController.swift (entry points), and
 * apps/web/src/editor/webmcp/register.ts (WebMCP tool split).
 */
const CHECKED = "2026-10-07";

const BIN = "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat";

const STANDARD_JSON = `{
  "mcpServers": {
    "capturecat": {
      "command": "${BIN}",
      "args": ["--mcp"]
    }
  }
}`;

const VSCODE_JSON = `{
  "servers": {
    "capturecat": {
      "command": "${BIN}",
      "args": ["--mcp"]
    }
  }
}`;

const CLI_COMMANDS = `# Claude Code (every project on this Mac)
claude mcp add --scope user capturecat -- "${BIN}" --mcp

# OpenAI Codex (CLI and app share ~/.codex/config.toml)
codex mcp add capturecat -- "${BIN}" --mcp

# Gemini CLI (every project on this Mac)
gemini mcp add -s user capturecat "${BIN}" --mcp`;

export const AI_AGENTS: DocSection = {
  id: "ai-agents",
  title: "AI agents (MCP)",
  description: "Let Claude, Codex, Cursor and other agents record and edit for you.",
  pages: [
    {
      slug: "ai-agents",
      title: "Screen recorder MCP server for Claude, Codex and Cursor",
      navTitle: "Overview",
      description:
        "CaptureCat's Mac app is an MCP server. Claude, Codex, Cursor and other agents can record your screen, edit recordings, check rendered frames and export.",
      summary:
        "The CaptureCat Mac app has a Model Context Protocol server built into its own binary: run it with `--mcp` and an AI agent can record the screen, search your captures, edit a recording with the editor's own rules, look at rendered frames, and export the video. There is no plugin or separate process to install.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "What an agent can do" },
        {
          type: "table",
          head: ["Area", "What it does", "Tools"],
          rows: [
            ["Record", "List displays and windows, start a recording of a display, a window, or a Chrome or Safari window (optionally opening a URL first), and stop it.", "`list_capture_targets`, `start_recording`, `stop_recording`"],
            ["Find", "List your projects, search the text inside your captures, and read your notes.", "`list_projects`, `search_captures`, `list_notes`"],
            ["Understand", "Read the whole timeline, where the clicks cluster, which stretches are idle or silent, and the timed transcript. Transcribe speech on your Mac if there is none yet.", "`describe_project`, `get_transcript`, `transcribe`, `style_options`"],
            ["Edit", "Zooms and tilts, auto zoom, annotations, privacy blur, speed regions, trim, cuts and every style setting, one at a time or as one batch.", "`apply_edits` and 16 single-edit tools"],
            ["Check", "Render frames of the final video, or a labelled contact sheet of up to 16 frames in one image, so the agent can see its own edits.", "`render_frames`"],
            ["Export", "Render the finished MP4 with the real export engine.", "`export_project`"],
          ],
        },
        {
          type: "p",
          text: "That is 28 tools in all. The [MCP tools reference](/docs/ai-agents/tools) lists each one.",
        },
        { type: "h2", text: "Set it up" },
        {
          type: "p",
          text: "Click the CaptureCat menu bar icon and choose **Connect AI Agents...**, then click **Install** next to your client. CaptureCat has one-click setup for Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI and VS Code, and a **Copy JSON** button for Windsurf and any other MCP client. See [Connect an AI agent](/docs/ai-agents/setup).",
        },
        { type: "h2", text: "How an agent edits" },
        {
          type: "p",
          text: "The server tells every client how CaptureCat edits work, so a capable agent follows the same loop on its own:",
        },
        {
          type: "steps",
          steps: [
            {
              title: "Describe",
              text: "`describe_project` returns the clips, effects and annotations with their ids, the click clusters (where attention goes) and the quiet spans with no motion, input or sound. With speech, the agent reads `get_transcript`, running `transcribe` first if needed.",
            },
            {
              title: "Plan and apply in one batch",
              text: "The agent sends the whole edit as one `apply_edits` call. Every operation is validated first; if any one fails, nothing is written and the error names the operation and the reason.",
            },
            {
              title: "Look",
              text: "`render_frames` with a contact sheet shows a grid of frames from the final render, each labelled with its time, so the agent can check framing, text placement and anything private.",
            },
            {
              title: "Fix, then export",
              text: "The agent corrects with another batch or `undo`, re-renders only what changed, and calls `export_project` when it looks right.",
            },
          ],
        },
        { type: "h2", text: "Safety" },
        {
          type: "list",
          items: [
            "**Media is never touched.** Tools only rewrite the project's edit list (`project.json`). Your recording, camera and audio files stay as they are.",
            "**Every write can be undone.** Before each write the server saves the previous edit list in the project folder (the last 30 in `.mcp-history`, plus `project.json.bak`). `undo` steps back through them.",
            "**The editor's rules apply.** Overlapping zooms, out-of-range times and invalid settings are refused with an error the agent can read and correct, instead of producing a broken project.",
            "**Recording is always visible.** `start_recording` shows the floating recording panel and a 3-2-1 countdown, and needs the same Screen Recording permission as recording by hand.",
            "**Edits show up in the app.** If CaptureCat is open, it reloads the project when an agent changes it. If you have that project open with unsaved changes, the app's copy wins, so save or close it before an agent edits it. The server warns the agent when this can happen.",
          ],
        },
        { type: "h2", text: "Built-in prompts" },
        {
          type: "p",
          text: "Clients that support MCP prompts (often shown as slash commands) get four ready-made workflows:",
        },
        {
          type: "table",
          head: ["Prompt", "What it does"],
          rows: [
            ["`polish_recording`", "Turns a raw recording into a clean video: trim, zooms, pacing, a few short callouts and privacy blur, checked with a contact sheet."],
            ["`tighten_pacing`", "Trims the start and end and speeds up idle stretches without touching speech."],
            ["`vertical_social_cut`", "Reframes a recording as a 9:16 short with tight zooms, fast pacing and captions."],
            ["`record_and_edit_demo`", "Records a browser demo of a URL, then edits it into a finished video."],
          ],
        },
        { type: "h2", text: "Things to ask" },
        {
          type: "list",
          items: [
            "Record my screen while I walk through the settings page, then add zooms where I clicked and export it to my Desktop.",
            "Open the latest recording, blur the email address in the top right for the whole video, and export it.",
            "Find the recording where `invoice` was on screen and tell me at what second it appears.",
            "Put the newest recording on a 9:16 canvas with captions, show me a contact sheet, then export.",
          ],
        },
        { type: "h2", text: "In the web editor" },
        {
          type: "p",
          text: "The browser editor also registers its editing tools through WebMCP, an emerging browser API, in browsers that support it. Browser agents get the same tool names and rules as the Mac server, minus recording, transcription and library search. See [WebMCP in the web editor](/docs/ai-agents/tools#webmcp-in-the-web-editor).",
        },
      ],
      faqs: [
        {
          question: "Is there a screen recorder with an MCP server?",
          answer:
            "Yes. CaptureCat's Mac app is an MCP server: run its binary with `--mcp` and agents such as Claude Code, Claude Desktop, Codex, Cursor and VS Code can record the screen, edit recordings and export video.",
        },
        {
          question: "Can Claude record and edit my screen?",
          answer:
            "With CaptureCat connected, yes. Claude can start and stop a recording (you always see the recording panel and countdown), then add zooms, cuts, captions and blur, look at rendered frames, and export an MP4.",
        },
        {
          question: "Does the MCP server send my recordings anywhere?",
          answer:
            "No. The server runs on your Mac and works on your local projects. Your agent client sees what the tools return, such as project details, transcripts and the frames it asks to render.",
        },
        {
          question: "Do I need a paid plan to use CaptureCat with AI agents?",
          answer: "No. The MCP server is part of the Mac app and works on the free plan.",
        },
      ],
      related: ["ai-agents/setup", "ai-agents/tools", "library"],
      lastModified: CHECKED,
    },
    {
      slug: "ai-agents/setup",
      title: "Connect Claude, Codex, Cursor or VS Code to CaptureCat",
      navTitle: "Connect an agent",
      description:
        "One-click MCP setup for Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI and VS Code from the CaptureCat Mac app, plus manual JSON for Windsurf.",
      summary:
        "Open **Connect AI Agents...** from the CaptureCat menu bar icon and click **Install** next to your client. The app fills in the path to its own binary, so there is nothing to type.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "One-click setup" },
        {
          type: "steps",
          steps: [
            {
              title: "Install CaptureCat",
              text: "The MCP server is the CaptureCat Mac app itself. See [Install CaptureCat](/docs/getting-started/install).",
            },
            {
              title: "Open Connect AI Agents",
              text: "Click the CaptureCat menu bar icon and choose **Connect AI Agents...**. You can also open **Settings → Account** and click **Connect…** next to **AI agents**.",
            },
            {
              title: "Click Install next to your client",
              text: "Each row shows **Installed** or **Not found** for apps CaptureCat can detect. What the button does depends on the client; see the table below.",
            },
            {
              title: "Restart the client",
              text: "Quit and reopen the client (or start a new session) so it loads the new server, then ask it to list your CaptureCat projects to check the connection.",
            },
          ],
        },
        {
          type: "table",
          head: ["Client", "What Install does"],
          rows: [
            ["**Claude Code**", "Opens Terminal and runs `claude mcp add` with user scope, so CaptureCat is available in every project on your Mac."],
            ["**Claude Desktop**", "Builds a CaptureCat extension bundle (`.mcpb`) and opens it in Claude Desktop, which asks you to confirm. If Claude Desktop is not installed, the bundle is shown in Finder for later."],
            ["**Cursor**", "Opens Cursor's install prompt for the server. If Cursor is not installed, the JSON config is copied instead."],
            ["**Codex**", "Opens Terminal and runs `codex mcp add`. The Codex app and CLI read the same config."],
            ["**Gemini CLI**", "Opens Terminal and runs `gemini mcp add` with user scope."],
            ["**VS Code**", "Opens VS Code's install prompt for the server, for use with GitHub Copilot's agent mode. If VS Code is not installed, the JSON config is copied instead."],
            ["**Windsurf & others**", "**Copy JSON** copies the standard `mcpServers` config to paste into any client's MCP settings."],
          ],
        },
        {
          type: "callout",
          tone: "note",
          title: "The Terminal permission prompt",
          text: "The first time you install for Claude Code, Codex or Gemini CLI, macOS asks whether CaptureCat may control Terminal. Allow it, and you can watch the exact command run. If you decline, CaptureCat copies the command so you can paste it into Terminal yourself.",
        },
        { type: "h2", text: "Manual setup" },
        {
          type: "p",
          text: "Every client runs the same thing: the CaptureCat binary with the `--mcp` argument, speaking MCP over standard input and output. If CaptureCat is in your Applications folder, the binary is at `/Applications/CaptureCat.app/Contents/MacOS/CaptureCat`.",
        },
        { type: "h3", text: "Command-line clients" },
        { type: "code", lang: "bash", code: CLI_COMMANDS },
        { type: "h3", text: "Claude Desktop, Cursor, Windsurf and most other clients" },
        {
          type: "p",
          text: "Add this to the client's MCP config. For Windsurf, that is `~/.codeium/windsurf/mcp_config.json`. Claude Desktop users can also download the [CaptureCat extension bundle](https://capturecat.so/CaptureCat.mcpb) and double-click it.",
        },
        { type: "code", lang: "json", caption: "Standard mcpServers config", code: STANDARD_JSON },
        { type: "h3", text: "VS Code" },
        {
          type: "p",
          text: "VS Code's `mcp.json` uses a `servers` key instead of `mcpServers`:",
        },
        { type: "code", lang: "json", caption: "VS Code mcp.json", code: VSCODE_JSON },
        { type: "h2", text: "Permissions" },
        {
          type: "list",
          items: [
            "**Editing, searching and exporting** need no extra permission.",
            "**Recording** uses the CaptureCat app, which opens automatically if it is not running, and needs Screen Recording permission like any recording. See [Make your first recording](/docs/getting-started/first-recording).",
            "**Transcription** downloads the on-device Whisper model (about 150 MB) the first time it runs. After that it works offline.",
          ],
        },
        {
          type: "callout",
          tone: "tip",
          title: "Exporting to a folder",
          text: "CaptureCat is sandboxed. If it cannot write to the path an agent asks for, `export_project` saves the video inside the app's container and returns that path, so the agent can copy it where you wanted it.",
        },
      ],
      faqs: [
        {
          question: "How do I add CaptureCat to Claude Code?",
          answer:
            "Choose Connect AI Agents... from the CaptureCat menu bar icon and click Install next to Claude Code, or run `claude mcp add --scope user capturecat -- \"/Applications/CaptureCat.app/Contents/MacOS/CaptureCat\" --mcp` in Terminal.",
        },
        {
          question: "Why does the agent not see CaptureCat after I installed it?",
          answer:
            "Most clients only load MCP servers when they start. Quit and reopen the client, or start a new session, then ask it to list your CaptureCat projects.",
        },
        {
          question: "I moved CaptureCat out of Applications. Does the setup still work?",
          answer:
            "One-click setup always uses the path the app is running from. If you set it up by hand, update the path in your client's config. The Claude Desktop bundle also looks in the standard install locations.",
        },
      ],
      related: ["ai-agents", "ai-agents/tools"],
      lastModified: CHECKED,
    },
    {
      slug: "ai-agents/tools",
      title: "CaptureCat MCP tools reference",
      navTitle: "Tools reference",
      description:
        "Every tool in CaptureCat's MCP server: recording, capture search, transcripts, zooms, annotations, blur, speed, trim, style, rendered frames and export.",
      summary:
        "CaptureCat's MCP server has 28 tools. Read-only tools never change anything; editing tools rewrite a project's edit list and can be undone with `undo`.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Two clocks" },
        {
          type: "p",
          text: "Edit tools take **source** seconds: positions in the original recording. `render_frames` and the start and end of transcript segments use **output** seconds: positions in the exported video, after trimming and speed changes. Results that matter for both, such as transcript words and search hits, carry both times. Positions on screen are fractions from 0 to 1 of the video frame, measured from the top left.",
        },
        { type: "h2", text: "Record" },
        {
          type: "table",
          head: ["Tool", "What it does"],
          rows: [
            ["`list_capture_targets`", "Lists the displays and on-screen windows you can record, with app name, title and size. Read-only."],
            ["`start_recording`", "Starts a recording of a display, a window matched by app or title, or a Chrome or Safari window. Can open a URL in the browser first, and records system audio unless told not to. Opens CaptureCat if needed; you always see the panel and countdown."],
            ["`stop_recording`", "Stops the recording, waits for it to save, and returns the new project's id."],
          ],
        },
        { type: "h2", text: "Find" },
        {
          type: "table",
          head: ["Tool", "What it does"],
          rows: [
            ["`list_projects`", "Lists every project with its id, name, creation date, duration, source kind and reminder date. Read-only."],
            ["`search_captures`", "Searches captures by what is visible in them (the on-device OCR index), plus titles and note text. Returns ranked matches with a snippet and, for videos, the best matching frame time. Read-only. See [Library and search](/docs/library)."],
            ["`list_notes`", "Lists your text notes with title, full text, source app and dates. Read-only. See [Notes](/docs/library/notes)."],
          ],
        },
        { type: "h2", text: "Understand" },
        {
          type: "table",
          head: ["Tool", "What it does"],
          rows: [
            ["`describe_project`", "Everything needed to plan an edit: duration and exported length, trim, clips, effects, annotations, blur, highlight and speed regions with ids, plus click clusters, idle cursor spans, silences and quiet spans. Read-only."],
            ["`get_transcript`", "The project's timed transcript, per segment and per word. Empty until subtitles exist. Read-only."],
            ["`transcribe`", "Generates subtitles on your Mac with the same Whisper model as the editor. Will not overwrite existing subtitles unless asked to replace them."],
            ["`style_options`", "Every `set_style` setting by group, with its type, allowed values and, for a project, its current value. Read-only."],
            ["`render_frames`", "Renders frames of the final video exactly as export would. Individual frames (up to 8) or a contact sheet of up to 16 labelled frames in one image, as PNG or JPEG. Read-only."],
          ],
        },
        { type: "h2", text: "Edit" },
        {
          type: "table",
          head: ["Tool", "What it does"],
          rows: [
            ["`apply_edits`", "Applies up to 200 edit operations to one project as a single all-or-nothing write and one undo step. Each operation is any edit tool below with its arguments."],
            ["`undo`", "Restores the project to before the last agent edits, up to 30 steps. Refuses if the project was changed outside the MCP server since, unless forced."],
            ["`auto_zoom`", "Runs the app's auto zoom on the recorded clicks, typing and pauses. Replaces earlier auto-generated zooms and works around manual ones."],
            ["`add_effect`", "Adds a zoom, a tilt, or a linked zoom and tilt to a time range. Blocks on the effects lane cannot overlap."],
            ["`update_effect`", "Changes the range, depth, focal point, tilt angles, animation style or cursor following of the block at a given time."],
            ["`remove_effect`", "Removes the zoom or tilt block at a given time."],
            ["`add_annotation`", "Adds text, an arrow, a callout, a rectangle, an ellipse or a tap indicator over a time range. Freehand drawing is editor-only."],
            ["`update_annotation`", "Moves, retimes, rewords or restyles an annotation."],
            ["`remove_annotation`", "Removes an annotation."],
            ["`add_blur`", "Blurs or pixelates a rectangle of the video over a time range, for emails, keys and customer data."],
            ["`remove_blur`", "Removes a blur region."],
            ["`set_speed`", "Plays a range faster or slower, from 0.5x to 4x, keeping audio pitch. Speed regions cannot overlap."],
            ["`remove_speed`", "Clears one speed region, the one at a given time, or all of them."],
            ["`set_trim`", "Sets where the video starts and ends, or resets to the full recording."],
            ["`cut_video`", "Removes ranges of footage. Like deleting a clip in the editor, the gap shows the background and the video keeps its length; use trim and speed to shorten it."],
            ["`set_style`", "Changes project settings such as background, padding, frame, cursor, camera, captions and aspect ratio. Unknown keys and invalid values are rejected with the allowed values."],
          ],
        },
        { type: "h2", text: "Export" },
        {
          type: "table",
          head: ["Tool", "What it does"],
          rows: [
            ["`export_project`", "Exports an MP4 with the app's export engine, reporting progress, to the path the agent gives. Overwrites an existing file there."],
          ],
        },
        { type: "h2", text: "WebMCP in the web editor", id: "webmcp-in-the-web-editor" },
        {
          type: "p",
          text: "The browser editor registers 22 of these tools through WebMCP, an emerging browser API, in browsers that support it, so an agent working in your browser can edit the open project. The tool names, rules and error messages are generated from the Mac server, so they behave the same way.",
        },
        {
          type: "list",
          items: [
            "**Available in the browser:** every Find, Understand and Edit tool except `search_captures`, `list_notes` and `transcribe`, plus `export_project`.",
            "**Mac only:** `list_capture_targets`, `start_recording`, `stop_recording`, `transcribe`, `search_captures` and `list_notes`.",
            "**Differences:** the project id is optional and defaults to the project open in the tab, `export_project` downloads the MP4 instead of writing to a path, and an extra read-only `get_editing_playbook` tool returns the editing guide the Mac server sends when a client connects.",
          ],
        },
      ],
      faqs: [
        {
          question: "How many tools does the CaptureCat MCP server have?",
          answer: "28: three for recording, three for finding captures, five for reading a project, sixteen for editing, and one for export.",
        },
        {
          question: "Can an agent undo its edits?",
          answer:
            "Yes. Every edit or batch is one step, and `undo` walks back up to 30 of them. Each write also keeps a backup of the previous edit list in the project folder.",
        },
        {
          question: "Can an agent see what the video looks like?",
          answer:
            "Yes. `render_frames` renders frames of the final video with every effect applied, or a labelled contact sheet of up to 16 frames in one image, so the agent can check its work before exporting.",
        },
      ],
      related: ["ai-agents", "ai-agents/setup", "library"],
      lastModified: CHECKED,
    },
  ],
};
