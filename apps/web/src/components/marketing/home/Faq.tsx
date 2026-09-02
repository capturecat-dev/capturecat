import { Container, SectionTitle } from "../primitives";

export interface FaqItem {
  q: string;
  a: string;
}

export const HOME_FAQ: FaqItem[] = [
  {
    q: "Is it actually free?",
    a: "Yes. Recording, the full editor, auto zoom, captions, and full quality export are free with no time limit and no resolution cap. Pro is only for the hosted features: share links, comments, and viewer analytics.",
  },
  {
    q: "Is it open source?",
    a: "Yes. The Mac app, the API, and this website are all in one public repository on GitHub under the AGPL-3.0 licence. You can read how auto zoom decides where to push in, build the app yourself, or self host the sharing side. Pro exists to pay for the hosted service, not to hide code.",
  },
  {
    q: "Does my audio go to a server for captions?",
    a: "No. Transcription runs on your Mac. The only time anything leaves your machine is when you choose to upload a video for a share link.",
  },
  {
    q: "Will the export look like the preview?",
    a: "Yes, and this is the thing we test hardest. The preview and the encoder share one set of maths for every zoom, tilt, cursor position, and caption. We run a frame by frame comparison against frozen reference renders before every release.",
  },
  {
    q: "Can I turn the automatic stuff off?",
    a: "Every effect is a switch. Auto zoom, cursor smoothing, ripples, key sounds, and captions can each be turned off, and any zoom the app placed is a normal block you can delete.",
  },
  {
    q: "What Macs does it run on?",
    a: "Any Mac on macOS 14 Sonoma or later. There are separate builds for Apple Silicon and Intel. iPhone and iPad recording needs a USB cable.",
  },
  {
    q: "Is it Electron?",
    a: "No. It is Swift and AppKit with Metal for rendering. Recording a 4K display uses less CPU than a browser tab.",
  },
  {
    q: "Can I edit old recordings from other tools?",
    a: "Not yet. Today the editor works on recordings made in CaptureCat, because the automatic effects depend on the click and keystroke data captured during the recording. Importing outside video is on the roadmap.",
  },
  {
    q: "What does the AI agent integration do?",
    a: "CaptureCat has a built in MCP server. Claude Code, Codex, Cursor, Copilot, and Windsurf can list your projects, read where you clicked, add or adjust effects, restyle the frame, and export, using the same engine as the editor. See the Agents page for setup.",
  },
];

export function FaqList({ items }: { items: FaqItem[] }) {
  return (
    <div className="divide-y divide-white/8 rounded-3xl border border-white/10 bg-white/[0.035] backdrop-blur-2xl">
      {items.map((item) => (
        <details key={item.q} className="group px-7 py-5 open:bg-white/[0.02]">
          <summary className="flex cursor-pointer list-none items-center justify-between gap-6 text-[16px] font-medium tracking-[-0.01em] text-foreground [&::-webkit-details-marker]:hidden">
            {item.q}
            <span
              aria-hidden
              className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full border border-white/12 bg-white/[0.06] text-muted-foreground transition-transform duration-300 group-open:rotate-45"
            >
              +
            </span>
          </summary>
          <p className="mt-3 max-w-2xl text-[15px] leading-relaxed text-muted-foreground">
            {item.a}
          </p>
        </details>
      ))}
    </div>
  );
}

export default function Faq() {
  return (
    <section id="faq" className="relative isolate py-24">
      <Container>
        <SectionTitle className="scroll-reveal">Questions people ask before downloading</SectionTitle>
        <div className="scroll-reveal mt-10 max-w-3xl">
          <FaqList items={HOME_FAQ} />
        </div>
      </Container>
    </section>
  );
}
