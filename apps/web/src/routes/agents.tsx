import type { ReactNode } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { Globe, Sparkles, Wrench } from "lucide-react";

import { jsonLd } from "@/lib/json-ld";
import { MCP_ENDPOINT, MCP_TOOLS, claudeMcpAddCommand } from "@/lib/agent-access";
import { pageHead } from "@/lib/site-content";
import {
  ClaudeLogo,
  OpenAILogo,
  CursorLogo,
  CopilotLogo,
  WindsurfLogo,
} from "@/components/marketing/ProviderLogos";
import { AgentSessionDemo, ConnectAgentsDemo } from "@/components/marketing/home/demo/AgentDemos";
import demosCss from "@/styles/demos.css?url";
import demosPagesCss from "@/styles/demos-pages.css?url";
import airyCss from "@/styles/airy.css?url";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import {
  AIR_CELL,
  AIR_GRID,
  AirCard,
  AirContainer,
  AirLede,
  AirPill,
  AirTitle,
  SoftFrame,
} from "@/components/marketing/airy/primitives";

export const Route = createFileRoute("/agents")({
  head: () =>
    pageHead("/agents", [
      { rel: "stylesheet", href: demosCss },
      { rel: "stylesheet", href: demosPagesCss },
      { rel: "stylesheet", href: airyCss },
    ]),
  component: AgentsPage,
});

const BIN = "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat";

const TOOL_GROUPS: Array<{ title: string; tools: Array<{ name: string; description: string }> }> = [
  {
    title: "Record and find",
    tools: [
      { name: "list_capture_targets", description: "The displays, windows, and connected devices available to record." },
      { name: "start_recording", description: "Start recording a chosen display, app, or web page." },
      { name: "stop_recording", description: "Stop and save the recording as a project, auto edit included." },
      { name: "list_projects", description: "Every recording in the library, with names, durations, and sources." },
      { name: "search_captures", description: "Search the text inside recordings, the same index as Command K." },
      { name: "list_notes", description: "Text notes captured from other apps." },
    ],
  },
  {
    title: "Read and edit",
    tools: [
      { name: "describe_project", description: "The full timeline plus an interaction digest and a pacing digest: click clusters, idle spans, and quiet stretches with no motion, input, or sound, so the agent knows where zooms and speed ups belong." },
      { name: "get_transcript", description: "The on device transcript with timestamps, per segment and per word." },
      { name: "transcribe", description: "Generate the transcript on device with the same Whisper model the editor uses." },
      { name: "apply_edits", description: "Apply a whole plan in one step. Every edit is checked first, and if one fails nothing is written." },
      { name: "undo", description: "Step back through the agent's edits, up to 30 of them." },
      { name: "auto_zoom", description: "Run the same auto zoom pass the app runs after recording." },
      { name: "add_effect", description: "Add a zoom, tilt, or zoom tilt block to a time range. Overlapping spans are refused, the same as in the editor." },
      { name: "update_effect", description: "Change the range, scale, or focal point of an existing block." },
      { name: "remove_effect", description: "Delete a block." },
      { name: "add_annotation", description: "Add text, an arrow, a callout, or a shape at a time and position." },
      { name: "update_annotation", description: "Move, retime, or reword an annotation." },
      { name: "remove_annotation", description: "Delete an annotation." },
      { name: "add_blur", description: "Blur or pixelate part of the screen for a time range, for emails, keys, and anything private." },
      { name: "remove_blur", description: "Delete a blur." },
      { name: "set_speed", description: "Speed up or slow down a section, with the same speeds the editor offers." },
      { name: "remove_speed", description: "Return a section to normal speed." },
      { name: "set_trim", description: "Set where the video starts and ends." },
      { name: "cut_video", description: "Cut a section out of the recording." },
      { name: "set_style", description: "Wallpaper, padding, shadow, frame, cursor, and the other project settings, validated by the same rules the app enforces." },
      { name: "style_options", description: "Every style setting with its allowed values and the project's current value." },
    ],
  },
  {
    title: "Check and export",
    tools: [
      { name: "render_frames", description: "Render frames, or a labelled contact sheet of many frames in one image, so the agent can look at its own edits before exporting." },
      { name: "export_project", description: "Render the final video with the real export engine, in process." },
    ],
  },
];

const jsonConfig = `{
  "mcpServers": {
    "capturecat": {
      "command": "${BIN}",
      "args": ["--mcp"]
    }
  }
}`;

const CLIENTS: Array<{
  name: string;
  logo: (props: { className?: string }) => React.JSX.Element;
  note: string;
  snippet: string;
  action?: { label: string; href: string };
}> = [
  {
    name: "Claude Code",
    logo: ClaudeLogo,
    note: "One command in your terminal.",
    snippet: `claude mcp add capturecat -- ${BIN} --mcp`,
  },
  {
    name: "Claude Desktop",
    logo: ClaudeLogo,
    note: "Download the extension bundle and double click it.",
    snippet: jsonConfig,
    action: {
      label: "Download extension (.mcpb)",
      href: "/CaptureCat.mcpb",
    },
  },
  {
    name: "OpenAI Codex",
    logo: OpenAILogo,
    note: "One command. The Codex app and CLI share the same config in ~/.codex/config.toml.",
    snippet: `codex mcp add capturecat -- ${BIN} --mcp`,
  },
  {
    name: "Cursor",
    logo: CursorLogo,
    note: "One click with Cursor installed, or add the JSON by hand.",
    snippet: jsonConfig,
    action: {
      label: "Add to Cursor",
      href: "cursor://anysphere.cursor-deeplink/mcp/install?name=capturecat&config=eyJjb21tYW5kIjoiL0FwcGxpY2F0aW9ucy9DYXB0dXJlQ2F0LmFwcC9Db250ZW50cy9NYWNPUy9DYXB0dXJlQ2F0IiwiYXJncyI6WyItLW1jcCJdfQ%3D%3D",
    },
  },
  {
    name: "GitHub Copilot",
    logo: CopilotLogo,
    note: "One click with VS Code installed, or add the JSON by hand.",
    action: {
      label: "Add to VS Code",
      href: "vscode:mcp/install?%7B%22name%22%3A%22capturecat%22%2C%22command%22%3A%22%2FApplications%2FCaptureCat.app%2FContents%2FMacOS%2FCaptureCat%22%2C%22args%22%3A%5B%22--mcp%22%5D%7D",
    },
    snippet: `{
  "servers": {
    "capturecat": {
      "command": "${BIN}",
      "args": ["--mcp"]
    }
  }
}`,
  },
  {
    name: "Windsurf",
    logo: WindsurfLogo,
    note: "Add to ~/.codeium/windsurf/mcp_config.json.",
    snippet: jsonConfig,
  },
];

const PROMPTS = [
  "Record my screen for 30 seconds while I walk through the settings page, then add zooms where I clicked and export it.",
  "Open the latest project, blur the email address in the top right for the whole video, and export at 1080p.",
  "Find the recording where I typed 'invoice' and tell me at what second it appears.",
  "Put the newest recording on the Sequoia wallpaper with 80 pixels of padding, add a title annotation for the first three seconds, render frame 2.0s so I can see it, then export.",
];

const jsonLdData = {
  "@context": "https://schema.org",
  "@type": "TechArticle",
  headline: "Use CaptureCat with AI agents over MCP",
  description:
    "Install instructions for connecting Claude, Codex, Cursor, GitHub Copilot, and Windsurf to CaptureCat's built in MCP server.",
  url: "https://capturecat.so/agents",
};

const CODE_BLOCK =
  "mt-4 overflow-x-auto rounded-2xl bg-[#0b0b10] p-4 text-[12.5px] leading-relaxed text-white/80 shadow-[inset_0_1px_0_rgb(255_255_255/0.06)]";
const INLINE_CODE = "rounded-md bg-black/[0.05] px-1.5 py-0.5 text-[13px] text-[var(--cc-air-ink)]";

function ClientHeader({ logo: Logo, name, note }: { logo: (props: { className?: string }) => React.JSX.Element; name: string; note: ReactNode }) {
  return (
    <div className="flex items-center gap-3">
      <span className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-[var(--cc-air-tint)] text-[var(--cc-air-ink)] ring-1 ring-black/[0.06]">
        <Logo className="h-5 w-5" />
      </span>
      <div>
        <h4 className="font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{name}</h4>
        <p className="text-[12.5px] text-[var(--cc-air-muted)]">{note}</p>
      </div>
    </div>
  );
}

function AgentsPage() {
  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <AirPageHero
        title="Your agent can record, edit, and export."
        lede="CaptureCat ships a Model Context Protocol server inside the app binary. No plugin, no sidecar process. Tell Claude Code, Codex, Cursor, Copilot, or Windsurf what you want and it uses the same engine as the editor."
        className="md:pb-16"
      >
        <div className="order-first mb-8 flex items-center justify-center gap-5 text-[var(--cc-air-ink-2)]">
          <ClaudeLogo className="h-7 w-7" />
          <OpenAILogo className="h-7 w-7" />
          <CursorLogo className="h-7 w-7" />
          <CopilotLogo className="h-7 w-7" />
          <WindsurfLogo className="h-7 w-7" />
        </div>
      </AirPageHero>

      <section className="pb-24 md:pb-32">
        <AirContainer className="max-w-5xl">
          <div className="air-bare">
            <AgentSessionDemo />
          </div>
          <p className="mt-4 text-center text-[13px] text-[var(--cc-air-faint)]">
            Claude Code adding zooms to a project while the editor updates.
          </p>
        </AirContainer>
      </section>

      <section className="border-t border-[var(--cc-air-hairline)] bg-white py-24 md:py-32">
        <AirContainer>
          <div className="scroll-reveal max-w-2xl">
            <AirPill icon={<Wrench className="h-3.5 w-3.5" strokeWidth={2} />}>MCP tools</AirPill>
            <AirTitle className="mt-5" muted="Every tool is validated by the same rules the editor uses.">
              30 tools.
            </AirTitle>
          </div>
          <div className="mt-14 space-y-12">
            {TOOL_GROUPS.map((group) => (
              <div key={group.title}>
                <h3 className="text-[13px] font-medium uppercase tracking-[0.08em] text-[var(--cc-air-faint)]">
                  {group.title}
                </h3>
                <div className={`${AIR_GRID} mt-4 sm:grid-cols-2 lg:grid-cols-3`}>
                  {group.tools.map((tool) => (
                    <div key={tool.name} className={`${AIR_CELL} p-6`}>
                      <code className="text-[13.5px] font-semibold text-[var(--cc-air-ink)]">{tool.name}</code>
                      <p className="mt-2 text-[14px] leading-relaxed text-[var(--cc-air-muted)]">{tool.description}</p>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
          <p className="mt-8 max-w-2xl text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">
            Edits are written atomically with a backup. Media files are never touched. Overlapping effects, out of
            range times, and invalid settings are refused with an error the agent can read, so it corrects itself
            instead of corrupting the project.
          </p>
        </AirContainer>
      </section>

      <section
        data-air-dark
        className="relative isolate overflow-hidden bg-[linear-gradient(180deg,#0b0b18_0%,#101a3a_100%)] py-24 md:py-32"
      >
        <div
          aria-hidden
          className="absolute inset-0 -z-10 bg-[radial-gradient(50%_60%_at_80%_0%,rgb(47_123_255/0.25),transparent_70%),radial-gradient(40%_50%_at_10%_100%,rgb(124_92_240/0.25),transparent_70%)]"
        />
        <AirContainer>
          <AirTitle dark className="scroll-reveal max-w-2xl" muted="Things people actually type.">
            Prompts that work.
          </AirTitle>
          <div className="mt-12 grid grid-cols-1 gap-4 md:grid-cols-2">
            {PROMPTS.map((p) => (
              <div
                key={p}
                className="scroll-reveal rounded-[20px] bg-white/[0.05] p-6 ring-1 ring-white/10 shadow-[inset_0_1px_0_rgb(255_255_255/0.06)]"
              >
                <p className="font-mono text-[13.5px] leading-relaxed text-white/85">
                  <span className="text-white/40">› </span>
                  {p}
                </p>
              </div>
            ))}
          </div>
        </AirContainer>
      </section>

      <section className="py-24 md:py-32">
        <AirContainer>
          <div className="scroll-reveal max-w-2xl">
            <AirTitle muted="The server is the app itself.">Install.</AirTitle>
            <AirLede className="mt-5">
              <code className={INLINE_CODE}>CaptureCat --mcp</code> speaks MCP over stdio. Install CaptureCat
              first, then register it in your client.
            </AirLede>
          </div>

          <div className="mt-14 grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-14">
            <div className="scroll-reveal lg:col-span-5">
              <AirPill icon={<Sparkles className="h-3.5 w-3.5" strokeWidth={2} />}>Easiest way</AirPill>
              <AirTitle as="h3" className="mt-5 !text-[28px] md:!text-[34px]">
                Let the app do it.
              </AirTitle>
              <AirLede className="mt-4">
                Open CaptureCat, click the menu bar icon, and choose Connect AI Agents. Pick your client and the app
                writes the config with the correct path resolved. Nothing to paste.
              </AirLede>
            </div>
            <div className="scroll-reveal lg:col-span-7">
              <SoftFrame>
                <ConnectAgentsDemo />
              </SoftFrame>
            </div>
          </div>

          <h3 className="mt-20 text-[13px] font-medium uppercase tracking-[0.08em] text-[var(--cc-air-faint)]">
            Or by hand
          </h3>
          <div className="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
            {CLIENTS.map((client) => (
              <AirCard key={client.name} as="article" className="min-w-0 p-6">
                <ClientHeader logo={client.logo} name={client.name} note={client.note} />
                {client.action && (
                  <a
                    href={client.action.href}
                    className="mt-4 inline-flex h-9 items-center justify-center rounded-full bg-[var(--cc-air-ink)] px-4 text-[13px] font-medium text-white transition-[transform,background-color] duration-300 hover:-translate-y-px hover:bg-[#1b1b22] active:translate-y-0"
                  >
                    {client.action.label}
                  </a>
                )}
                <pre className={CODE_BLOCK}>
                  <code>{client.snippet}</code>
                </pre>
              </AirCard>
            ))}
          </div>
          <p className="mt-6 max-w-2xl text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">
            One thing to know: an open project reloads the agent's edits automatically, unless it has unsaved
            changes in the editor. Then your in-app edits win, so save before handing a project to an agent. The
            server warns about exactly this if it happens.
          </p>
        </AirContainer>
      </section>

      <section className="bg-[var(--cc-air-tint)] py-24 md:py-32">
        <AirContainer>
          <div className="scroll-reveal max-w-3xl">
            <AirPill icon={<Globe className="h-3.5 w-3.5" strokeWidth={2} />}>Remote MCP</AirPill>
            <AirTitle className="mt-5" muted="For agents that don't run on your Mac.">
              Connect any agent.
            </AirTitle>
            <AirLede className="mt-5">
              CaptureCat also runs a remote MCP server at <code className={INLINE_CODE}>{MCP_ENDPOINT}</code>.
              Claude.ai, Claude Code, ChatGPT or a scheduled agent can list your shared videos, read transcripts,
              comments and analytics, reply to viewers, change share settings, and edit your cloud projects (zooms,
              cuts, speed, blur, annotations, style) without the editor open.
            </AirLede>
            <AirLede className="mt-4">
              Claude.ai and ChatGPT need only the URL: add a custom connector and sign in with CaptureCat. Other
              clients use a token from Settings, Agent access. Either way the agent gets only the permissions you
              allow, never more than your plan, and you can revoke it at any time.
            </AirLede>
          </div>
          <div className="mt-12 grid grid-cols-1 gap-4 lg:grid-cols-2">
            <AirCard as="article" className="min-w-0 p-6">
              <ClientHeader logo={ClaudeLogo} name="Claude Code" note="Paste your token in place of <token>." />
              <pre className={CODE_BLOCK}>
                <code>{claudeMcpAddCommand("<token>")}</code>
              </pre>
            </AirCard>
            <AirCard as="article" className="min-w-0 p-6">
              <ClientHeader
                logo={OpenAILogo}
                name="Claude.ai or ChatGPT"
                note="Add a custom connector with this URL, then sign in with CaptureCat. No token to paste."
              />
              <pre className={CODE_BLOCK}>
                <code>{MCP_ENDPOINT}</code>
              </pre>
              <p className="mt-3 text-[12.5px] text-[var(--cc-air-muted)]">
                Any other MCP client: the same URL, signing in with OAuth or sending a token as{" "}
                <code className="text-[11.5px] text-[var(--cc-air-ink)]">Authorization: Bearer &lt;token&gt;</code>.
              </p>
            </AirCard>
          </div>
          <div className="mt-6 flex max-w-3xl flex-wrap gap-1.5">
            {MCP_TOOLS.map((tool) => (
              <code
                key={tool.name}
                title={`${tool.summary} Scope: ${tool.scope}.`}
                className="rounded-full bg-white px-2.5 py-1 text-[12px] text-[var(--cc-air-ink-2)] ring-1 ring-black/[0.07]"
              >
                {tool.name}
              </code>
            ))}
          </div>
          <p className="mt-6 max-w-2xl text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">
            No delete or billing tools. Comments an agent posts show your name followed by "(via agent)", every
            project edit is a version in History you can restore, every call lands in your activity log, and text
            written by viewers comes back marked as untrusted. Before an agent posts a comment or makes a video
            viewable to more people, it asks you first with a link to approve. Webhooks can tell your agent when a
            video is ready or a viewer comments.{" "}
            <a
              href="/auth.md"
              className="font-medium text-[var(--cc-air-ink)] underline decoration-black/20 underline-offset-4 hover:decoration-black/60"
            >
              How sign-in, tokens and webhooks work
            </a>
            .
          </p>
        </AirContainer>
      </section>
    </AirPage>
  );
}
