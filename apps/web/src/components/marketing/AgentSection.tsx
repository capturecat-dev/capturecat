import { Link } from "@tanstack/react-router";

import {
  ClaudeLogo,
  OpenAILogo,
  CursorLogo,
  CopilotLogo,
  WindsurfLogo,
} from "./ProviderLogos";
import { Ambient, Container, SectionTitle } from "./primitives";

/**
 * Home page teaser for /agents.
 *
 * The terminal loops a typed command and the tool calls the MCP server
 * actually makes (the tool names are real). Pure CSS animation, reduced
 * motion safe.
 */
export default function AgentSection() {
  return (
    <section className="relative isolate py-24">
      <Ambient variant="bottom" />

      <Container>
        <div className="grid grid-cols-1 items-center gap-12 lg:grid-cols-2 lg:gap-16">
          <div className="scroll-reveal">
            <div className="flex items-center gap-4 text-muted-foreground">
              <ClaudeLogo className="h-6 w-6" />
              <OpenAILogo className="h-6 w-6" />
              <CursorLogo className="h-6 w-6" />
              <CopilotLogo className="h-6 w-6" />
              <WindsurfLogo className="h-6 w-6" />
            </div>
            <SectionTitle className="mt-6" muted="Your coding agent can drive the editor.">
              Do not feel like opening the app?
            </SectionTitle>
            <p className="mt-6 max-w-lg text-pretty text-lg leading-relaxed text-muted-foreground">
              CaptureCat has a Model Context Protocol server built into the app
              binary. Claude Code, Codex, Cursor, Copilot, or Windsurf can
              start a recording, read where you clicked, add the zooms, restyle
              the frame, render frames to check their own work, and export.
              Same engine as the editor, so the result is identical.
            </p>
            <Link
              to="/agents"
              className="mt-8 inline-flex h-12 items-center justify-center rounded-full border border-white/12 bg-white/[0.06] px-7 text-[15px] font-medium text-foreground backdrop-blur-xl transition-colors duration-300 hover:border-white/20 hover:bg-white/[0.10]"
            >
              Set up your agent
            </Link>
          </div>

          <div className="scroll-reveal">
            <div className="relative overflow-hidden rounded-[24px] border border-white/12 bg-black/50 shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] backdrop-blur-2xl">
              <span
                aria-hidden
                className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
              />
              <div className="flex h-10 items-center gap-2 border-b border-white/10 px-4">
                <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                <span className="ml-3 text-xs text-muted-foreground">claude</span>
              </div>
              <div className="space-y-2.5 p-5 font-mono text-[13px] leading-relaxed">
                <div className="text-foreground">
                  <span className="text-muted-foreground">$ </span>
                  <span className="cc-type">
                    claude &quot;add zooms where I clicked, then export&quot;
                  </span>
                  <span className="cc-caret text-muted-foreground">▌</span>
                </div>
                <div className="cc-tool-line cc-tool-line-1 text-muted-foreground">
                  <span className="text-cyan-300/90">⏺ describe_project</span> found 3
                  click clusters
                </div>
                <div className="cc-tool-line cc-tool-line-2 text-muted-foreground">
                  <span className="text-cyan-300/90">⏺ add_effect</span> zoom
                  0:04 to 0:09, 0:12 to 0:16, 0:21 to 0:24
                </div>
                <div className="cc-tool-line cc-tool-line-3 text-muted-foreground">
                  <span className="text-cyan-300/90">⏺ export_project</span> wrote
                  ~/Movies/demo-final.mp4
                </div>
                <div className="cc-tool-line cc-tool-line-4 text-emerald-300/90">
                  ✓ Done. Zooms placed on each click cluster.
                </div>
              </div>
            </div>
            <p className="mt-4 text-center text-sm text-muted-foreground">
              Real tool names. 17 tools in total, listed on the Agents page.
            </p>
          </div>
        </div>
      </Container>
    </section>
  );
}
