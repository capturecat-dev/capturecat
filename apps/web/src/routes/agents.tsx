import { createFileRoute } from "@tanstack/react-router";

import { jsonLd } from "@/lib/json-ld";
import { markdownAlternateLinks } from "@/lib/site-content";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import {
  ClaudeLogo,
  OpenAILogo,
  CursorLogo,
  CopilotLogo,
  WindsurfLogo,
} from "@/components/marketing/ProviderLogos";
import { MediaPlaceholder } from "@/components/marketing/MediaPlaceholder";
import {
  Ambient,
  Container,
  Eyebrow,
  GlassCard,
  SectionTitle,
} from "@/components/marketing/primitives";

export const Route = createFileRoute("/agents")({
  head: () => ({
    meta: [
      { title: "Agents and MCP | CaptureCat" },
      {
        name: "description",
        content:
          "CaptureCat has a built in MCP server. Let Claude, Codex, Cursor, Copilot, or Windsurf record, inspect, edit, restyle, and export your recordings. No plugin needed.",
      },
    ],
    links: markdownAlternateLinks("/agents"),
  }),
  component: AgentsPage,
});

const BIN = "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat";

const TOOL_GROUPS: Array<{ title: string; tools: Array<{ name: string; description: string }> }> = [
  {
    title: "Record and find",
    tools: [
      { name: "list_capture_targets", description: "The displays, windows, and connected devices available to record." },
      { name: "start_recording", description: "Start a recording of a chosen target, with camera and mic options." },
      { name: "stop_recording", description: "Stop and save the recording as a project, auto edit included." },
      { name: "list_projects", description: "Every recording in the library, with names, durations, and sources." },
      { name: "search_captures", description: "Search the text inside recordings, the same index as Command K." },
      { name: "list_notes", description: "Text notes captured from other apps." },
    ],
  },
  {
    title: "Read and edit",
    tools: [
      { name: "describe_project", description: "The full timeline plus an interaction digest: click clusters and idle spans from the recorded cursor data, so the agent knows where zooms belong." },
      { name: "get_transcript", description: "The on device transcript with timestamps." },
      { name: "auto_zoom", description: "Run the same auto zoom pass the app runs after recording." },
      { name: "add_effect", description: "Add a zoom, tilt, or zoom tilt block to a time range. Overlapping spans are refused, the same as in the editor." },
      { name: "update_effect", description: "Change the range, scale, or focal point of an existing block." },
      { name: "remove_effect", description: "Delete a block." },
      { name: "add_annotation", description: "Add text, an arrow, a callout, or a shape at a time and position." },
      { name: "remove_annotation", description: "Delete an annotation." },
      { name: "cut_video", description: "Cut a section out of the recording." },
      { name: "set_style", description: "Wallpaper, padding, shadow, frame, cursor, and the other project settings, validated by the same rules the app enforces." },
    ],
  },
  {
    title: "Check and export",
    tools: [
      { name: "render_frames", description: "Render specific frames to images so the agent can look at its own edits before exporting." },
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

function AgentsPage() {
  return (
    <main className="flex min-h-screen flex-col bg-background">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <Ambient variant="hero" />
        <Container className="pb-16 pt-16 text-center md:pt-24">
          <div className="mx-auto mb-8 flex items-center justify-center gap-5 text-muted-foreground">
            <ClaudeLogo className="h-7 w-7" />
            <OpenAILogo className="h-7 w-7" />
            <CursorLogo className="h-7 w-7" />
            <CopilotLogo className="h-7 w-7" />
            <WindsurfLogo className="h-7 w-7" />
          </div>
          <h1 className="mx-auto max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            Your agent can record, edit, and export.
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            CaptureCat ships a Model Context Protocol server inside the app
            binary. No plugin, no sidecar process. Tell Claude Code, Codex,
            Cursor, Copilot, or Windsurf what you want and it uses the same
            engine as the editor.
          </p>
        </Container>
      </section>

      <section className="relative isolate py-8">
        <Container>
          <MediaPlaceholder id="agents-session" />
          <p className="mt-3 text-center text-sm text-muted-foreground">
            Claude Code adding zooms to a project while the editor updates.
          </p>
        </Container>
      </section>

      <section className="relative isolate py-16">
        <Container>
          <SectionTitle muted="Every tool is validated by the same rules the editor uses.">
            17 tools
          </SectionTitle>
          <div className="mt-10 space-y-8">
            {TOOL_GROUPS.map((group) => (
              <div key={group.title}>
                <h3 className="text-[13px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                  {group.title}
                </h3>
                <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
                  {group.tools.map((tool) => (
                    <GlassCard key={tool.name} padding="p-6">
                      <code className="text-sm font-medium text-foreground">{tool.name}</code>
                      <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                        {tool.description}
                      </p>
                    </GlassCard>
                  ))}
                </div>
              </div>
            ))}
          </div>
          <p className="mt-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
            Edits are written atomically with a backup. Media files are never
            touched. Overlapping effects, out of range times, and invalid
            settings are refused with an error the agent can read, so it
            corrects itself instead of corrupting the project.
          </p>
        </Container>
      </section>

      <section className="relative isolate py-16">
        <Container>
          <SectionTitle muted="Things people actually type.">Prompts that work</SectionTitle>
          <div className="mt-10 grid grid-cols-1 gap-4 md:grid-cols-2">
            {PROMPTS.map((p) => (
              <GlassCard key={p} padding="p-6">
                <p className="font-mono text-[13.5px] leading-relaxed text-foreground/90">
                  <span className="text-muted-foreground">› </span>
                  {p}
                </p>
              </GlassCard>
            ))}
          </div>
        </Container>
      </section>

      <section className="relative isolate py-16">
        <Container>
          <SectionTitle muted="The server is the app itself.">Install</SectionTitle>
          <p className="mt-4 max-w-2xl text-muted-foreground">
            <code className="rounded bg-white/[0.07] px-1.5 py-0.5 text-[13px]">
              CaptureCat --mcp
            </code>{" "}
            speaks MCP over stdio. Install CaptureCat first, then register it
            in your client.
          </p>

          <div className="mt-8 grid grid-cols-1 items-center gap-8 lg:grid-cols-12 lg:gap-14">
            <div className="lg:col-span-5">
              <Eyebrow>Easiest way</Eyebrow>
              <h3 className="mt-4 text-2xl font-medium tracking-[-0.02em]">
                Let the app do it.
              </h3>
              <p className="mt-3 text-[15px] leading-relaxed text-muted-foreground">
                Open CaptureCat, click the menu bar icon, and choose Connect AI
                Agents. Pick your client and the app writes the config with the
                correct path resolved. Nothing to paste.
              </p>
            </div>
            <div className="lg:col-span-7">
              <MediaPlaceholder id="agents-connect-menu" />
            </div>
          </div>

          <h3 className="mt-16 text-[13px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
            Or by hand
          </h3>
          <div className="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
            {CLIENTS.map((client) => (
              <GlassCard key={client.name} padding="p-6">
                <div className="flex items-center gap-3">
                  <span className="inline-flex h-10 w-10 items-center justify-center rounded-2xl border border-white/12 bg-white/[0.07]">
                    <client.logo className="h-5 w-5" />
                  </span>
                  <div>
                    <h4 className="font-medium tracking-[-0.01em]">{client.name}</h4>
                    <p className="text-xs text-muted-foreground">{client.note}</p>
                  </div>
                </div>
                {client.action && (
                  <a
                    href={client.action.href}
                    className="mt-4 inline-flex h-9 items-center justify-center rounded-full bg-white px-4 text-[13px] font-medium text-black transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98]"
                  >
                    {client.action.label}
                  </a>
                )}
                <pre className="mt-4 overflow-x-auto rounded-2xl border border-white/8 bg-black/40 p-4 text-[12.5px] leading-relaxed text-muted-foreground">
                  <code>{client.snippet}</code>
                </pre>
              </GlassCard>
            ))}
          </div>
          <p className="mt-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
            One thing to know: close a project in the CaptureCat editor before
            letting an agent edit it. The editor autosaves and would overwrite
            the agent's changes. The server warns about exactly this if it
            happens.
          </p>
        </Container>
      </section>

      <Footer />
    </main>
  );
}
