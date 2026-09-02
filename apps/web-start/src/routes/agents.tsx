import { createFileRoute } from "@tanstack/react-router";

import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import {
  ClaudeLogo,
  OpenAILogo,
  CursorLogo,
  CopilotLogo,
  WindsurfLogo,
} from "@/components/landing/ProviderLogos";
import { markdownAlternateLinks } from "@/lib/site-content";

export const Route = createFileRoute("/agents")({
  head: () => ({
    meta: [
      { title: "Agents & MCP | CaptureCat" },
      {
        name: "description",
        content:
          "CaptureCat ships a built-in MCP server: let Claude, ChatGPT, Cursor, Copilot, or Windsurf inspect your recordings, add zooms, restyle projects, and export — no plugin needed.",
      },
    ],
    links: markdownAlternateLinks("/agents"),
  }),
  component: AgentsPage,
});

const BIN = "/Applications/CaptureCat.app/Contents/MacOS/CaptureCat";

const TOOLS = [
  {
    name: "list_projects",
    description: "Every recording in your library — names, durations, sources.",
  },
  {
    name: "describe_project",
    description:
      "The full timeline plus an interaction digest: click clusters and idle spans from the recorded cursor data, so the agent knows where zooms belong.",
  },
  {
    name: "add_effect",
    description:
      "Add zoom, tilt, or zoom-tilt effects to a time range. Overlapping spans are refused, exactly like in the editor.",
  },
  {
    name: "set_style",
    description:
      "Change wallpaper, padding, shadows, and other settings — validated against the same rules the app enforces.",
  },
  {
    name: "export_project",
    description:
      "Render the final video with the real export engine, in-process.",
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
  /** One-click install (deep link or download) where the client supports it. */
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
    note: "One click: download the extension bundle and double-click it.",
    snippet: jsonConfig,
    action: {
      label: "Download extension (.mcpb)",
      href: "/CaptureCat.mcpb",
    },
  },
  {
    name: "OpenAI Codex",
    logo: OpenAILogo,
    note: "One command — the Codex desktop app and CLI share the same config (~/.codex/config.toml).",
    snippet: `codex mcp add capturecat -- ${BIN} --mcp`,
  },
  {
    name: "Cursor",
    logo: CursorLogo,
    note: "One click with Cursor installed — or add the JSON manually.",
    snippet: jsonConfig,
    action: {
      label: "Add to Cursor",
      href: "cursor://anysphere.cursor-deeplink/mcp/install?name=capturecat&config=eyJjb21tYW5kIjoiL0FwcGxpY2F0aW9ucy9DYXB0dXJlQ2F0LmFwcC9Db250ZW50cy9NYWNPUy9DYXB0dXJlQ2F0IiwiYXJncyI6WyItLW1jcCJdfQ%3D%3D",
    },
  },
  {
    name: "GitHub Copilot",
    logo: CopilotLogo,
    note: "One click with VS Code installed — or add the JSON manually.",
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

const jsonLd = {
  "@context": "https://schema.org",
  "@type": "TechArticle",
  headline: "Use CaptureCat with AI agents over MCP",
  description:
    "Install instructions for connecting Claude, ChatGPT, Cursor, GitHub Copilot, and Windsurf to CaptureCat's built-in MCP server.",
  url: "https://capturecat.so/agents",
};

function AgentsPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 -z-10"
          style={{
            background:
              "radial-gradient(120% 80% at 50% -20%, rgba(120,140,255,0.18), transparent 60%)," +
              "radial-gradient(70% 50% at 85% 20%, rgba(80,220,255,0.10), transparent 55%)",
          }}
        />
        <div className="mx-auto max-w-6xl px-6 pb-16 pt-20 text-center md:pt-28">
          <div className="mx-auto mb-8 flex items-center justify-center gap-5 text-muted-foreground">
            <ClaudeLogo className="h-7 w-7" />
            <OpenAILogo className="h-7 w-7" />
            <CursorLogo className="h-7 w-7" />
            <CopilotLogo className="h-7 w-7" />
            <WindsurfLogo className="h-7 w-7" />
          </div>
          <h1 className="mx-auto max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            Your agent can edit your recordings.
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            CaptureCat ships a Model Context Protocol server inside the app —
            no plugin, no sidecar. Tell Claude, ChatGPT, Cursor, Copilot, or
            Windsurf to add zooms where you clicked, restyle a project, and
            export the final video.
          </p>
        </div>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 pb-8">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">What agents can do</h2>
        <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
          {TOOLS.map((tool) => (
            <article
              key={tool.name}
              className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl"
            >
              <span
                aria-hidden
                className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
              />
              <code className="text-sm font-medium text-foreground">{tool.name}</code>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                {tool.description}
              </p>
            </article>
          ))}
        </div>
        <p className="mt-4 text-sm text-muted-foreground">
          Edits are written atomically with a backup, media files are never
          touched, and the same validation the editor runs applies to every
          agent change.
        </p>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 py-16">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">Install</h2>
        <p className="mt-2 max-w-2xl text-muted-foreground">
          The server is the app binary itself:{" "}
          <code className="rounded bg-white/[0.07] px-1.5 py-0.5 text-[13px]">
            CaptureCat --mcp
          </code>{" "}
          speaks MCP over stdio. Install CaptureCat first, then register it in
          your client:
        </p>
        <div className="mt-6 flex items-start gap-3 rounded-2xl border border-cyan-300/20 bg-cyan-400/[0.06] px-5 py-4">
          <span aria-hidden className="mt-0.5 h-2 w-2 shrink-0 rounded-full bg-cyan-300/80" />
          <p className="text-sm leading-relaxed text-muted-foreground">
            <span className="font-medium text-foreground">Easiest:</span> open
            CaptureCat and pick{" "}
            <span className="text-foreground">
              menu&nbsp;bar&nbsp;→&nbsp;Connect&nbsp;AI&nbsp;Agents…
            </span>{" "}
            — the app installs the connection for your client itself, with the
            correct path resolved automatically.
          </p>
        </div>
        <div className="mt-8 grid grid-cols-1 gap-4 lg:grid-cols-2">
          {CLIENTS.map((client) => (
            <article
              key={client.name}
              className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl"
            >
              <span
                aria-hidden
                className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
              />
              <div className="flex items-center gap-3">
                <span className="inline-flex h-10 w-10 items-center justify-center rounded-2xl border border-white/12 bg-white/[0.07]">
                  <client.logo className="h-5 w-5" />
                </span>
                <div>
                  <h3 className="font-medium tracking-[-0.01em]">{client.name}</h3>
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
            </article>
          ))}
        </div>
        <p className="mt-6 text-sm text-muted-foreground">
          Tip: close a project in the CaptureCat editor before letting an agent
          edit it — the app&apos;s autosave wins otherwise, and the server will
          warn you about exactly that.
        </p>
      </section>

      <Footer />
    </main>
  );
}
