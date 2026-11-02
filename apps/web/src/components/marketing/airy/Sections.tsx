import { useEffect, useRef, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import {
  AppWindow,
  Bot,
  Captions,
  ChevronDown,
  CircleDot,
  Gauge,
  Globe,
  Keyboard,
  Layers,
  Link2,
  Monitor,
  MousePointer2,
  ScanSearch,
  Scissors,
  ShieldCheck,
  SlidersHorizontal,
  Smartphone,
  Sparkles,
  UserRound,
  ZoomIn,
} from "lucide-react";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { Canvas, EditorMock } from "../home/demo/parts";
import { Meter } from "../home/demo/RecordingScene";
import { AgentSessionDemo } from "../home/demo/AgentDemos";
import { useOffscreenPause } from "../home/demo/hooks";
import { AppleGlyph, GITHUB_URL, GitHubIcon } from "../primitives";
import { AirContainer, AirLede, AirPill, AirTitle, GHOST_ON_DARK, InkLink, SoftAnchor } from "./primitives";

// ── Dark band: what happens after record ────────────────────────────────────

const STEPS = [
  { href: "#zoom", label: "Zoom", icon: ZoomIn },
  { href: "#cursor", label: "Cursor", icon: MousePointer2 },
  { href: "#layouts", label: "Camera", icon: UserRound },
  { href: "#captions", label: "Captions", icon: Captions },
  { href: "#share", label: "Share", icon: Link2 },
] as const;

export function CapabilityBand() {
  return (
    <section data-air-dark className="relative isolate overflow-hidden bg-[#0b0b10] py-20 md:py-24">
      <div
        aria-hidden
        className="absolute inset-0 -z-10 bg-[radial-gradient(60%_80%_at_50%_120%,rgb(124_92_240/0.35),transparent_70%)]"
      />
      <AirContainer className="text-center">
        <AirTitle dark className="mx-auto max-w-2xl !text-[32px] md:!text-[44px]">
          You record.
          <br />
          <span className="text-white/45">CaptureCat does the rest.</span>
        </AirTitle>
        <ul className="mx-auto mt-12 grid max-w-3xl grid-cols-5 gap-2">
          {STEPS.map((s) => (
            <li key={s.href}>
              <a
                href={s.href}
                className="group flex flex-col items-center gap-2.5 rounded-2xl py-3 text-[13px] text-white/70 transition-colors hover:text-white"
              >
                <span className="inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-white/[0.06] ring-1 ring-white/10 transition-[transform,background-color] duration-300 group-hover:-translate-y-0.5 group-hover:bg-white/[0.1]">
                  <s.icon className="h-[22px] w-[22px]" strokeWidth={1.6} />
                </span>
                {s.label}
              </a>
            </li>
          ))}
        </ul>
      </AirContainer>
    </section>
  );
}

// ── Mac + browser ───────────────────────────────────────────────────────────

export function Everywhere() {
  const pairRef = useOffscreenPause<HTMLDivElement>();
  return (
    <section id="everywhere" className="relative scroll-mt-24 bg-[var(--cc-air-tint)] py-24 md:py-32">
      <AirContainer>
        <div className="scroll-reveal mx-auto flex max-w-2xl flex-col items-center text-center">
          <AirPill icon={<Globe className="h-3.5 w-3.5" strokeWidth={2} />}>Mac app + browser app</AirPill>
          <AirTitle className="mt-5">
            One editor.{" "}
            <span className="text-[var(--cc-air-faint)]">On your Mac, and in any browser.</span>
          </AirTitle>
          <AirLede className="mt-5">
            The Mac app is native Swift. The browser app runs the same editor on WebGPU, so Windows, Linux and
            ChromeOS can record, restyle and export too. Projects move between the two in one click.
          </AirLede>
        </div>

        <div ref={pairRef} className="ccd scroll-reveal mx-auto mt-14 max-w-4xl" aria-hidden>
          <div className="ccd-pair ccd-live">
            <div className="ccd-pair-win ccd-pair-mac">
              <EditorMock
                script="pair"
                title="Launch video — CaptureCat"
                duration={10}
                lanes={[
                  { name: "VIDEO" },
                  {
                    name: "EFFECTS",
                    blocks: [
                      { className: "ccd-b1", left: 11, width: 35, label: "Zoom 1.9×" },
                      { className: "ccd-b2", left: 52, width: 32, label: "Zoom 1.9×" },
                    ],
                  },
                ]}
              />
            </div>
            <div className="ccd-pair-win ccd-pair-web">
              <div className="ccd-tabs">
                <span className="ccd-lights">
                  <i />
                  <i />
                  <i />
                </span>
                <span className="ccd-tab">
                  <i />
                  Record · CaptureCat
                </span>
              </div>
              <div className="ccd-urlbar">
                <span className="ccd-url">
                  <b>app.capturecat.so</b>/record
                </span>
              </div>
              <div className="ccd-webapp">
                <div className="ccd-webside">
                  <span>Library</span>
                  <span className="is-on">Record</span>
                  <span>Projects</span>
                  <span>Team</span>
                  <span>Settings</span>
                </div>
                <div className="ccd-webmain">
                  <div className="ccd-webpreview">
                    <Canvas script="raw" />
                  </div>
                  <div className="ccd-webbar">
                    <div className="ccd-rec-tabs">
                      <span className="ccd-rec-pill" />
                      <span className="ccd-rec-tab is-on">
                        <Monitor strokeWidth={1.6} />
                        Display
                      </span>
                      <span className="ccd-rec-tab">
                        <AppWindow strokeWidth={1.6} />
                        Window
                      </span>
                      <span className="ccd-rec-tab">
                        <Globe strokeWidth={1.6} />
                        Tab
                      </span>
                    </div>
                    <span className="ccd-rec-div" />
                    <span className="ccd-rec-key">
                      <Monitor className="ccd-dim" />
                      Entire Screen
                      <ChevronDown className="ccd-dim" />
                    </span>
                    <span className="ccd-rec-div" />
                    <span className="ccd-rec-key">
                      <SlidersHorizontal className="ccd-dim" />
                      <Meter />
                      Mic · Cam
                    </span>
                    <span className="ccd-rec-record">
                      <CircleDot strokeWidth={2.2} />
                    </span>
                  </div>
                </div>
              </div>
            </div>
            <div className="ccd-sync">
              Open in Web Editor <i>⇄</i> Pull Web Edits
            </div>
          </div>
        </div>

        <div className="mt-12 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <InkLink to="/download">
            <AppleGlyph />
            Download for Mac
          </InkLink>
          <SoftAnchor href="https://app.capturecat.so/record">
            <Globe className="h-[18px] w-[18px]" strokeWidth={1.75} />
            Open the browser app
          </SoftAnchor>
        </div>
        <p className="mt-4 text-center text-[13px] text-[var(--cc-air-faint)]">
          <Link to="/compare" className="underline-offset-4 hover:text-[var(--cc-air-ink-2)] hover:underline">
            What each one can record
          </Link>
        </p>
      </AirContainer>
    </section>
  );
}

// ── 2 × 2 details ───────────────────────────────────────────────────────────

function DetailCard({ title, body, children }: { title: string; body: string; children: ReactNode }) {
  return (
    <div className="scroll-reveal overflow-hidden rounded-[28px] bg-white shadow-[0_1px_2px_rgb(0_0_0/0.04),0_24px_60px_-36px_rgb(30_20_90/0.35)] ring-1 ring-black/[0.06]">
      <div className="relative flex h-56 items-center justify-center overflow-hidden bg-[var(--cc-air-tint)] md:h-64">
        {children}
      </div>
      <div className="p-7">
        <h3 className="text-[19px] font-semibold tracking-[-0.02em] text-[var(--cc-air-ink)]">{title}</h3>
        <p className="mt-2 text-[15px] leading-relaxed text-[var(--cc-air-muted)]">{body}</p>
      </div>
    </div>
  );
}

const MINI_WALL = "bg-[linear-gradient(135deg,#bf5af2_0%,#7d5cf0_45%,#0a84ff_100%)]";

export function DetailCards() {
  return (
    <section className="py-24 md:py-32">
      <AirContainer>
        <div className="scroll-reveal mx-auto max-w-2xl text-center">
          <AirTitle>
            The small things,{" "}
            <span className="text-[var(--cc-air-faint)]">already handled.</span>
          </AirTitle>
        </div>
        <div className="mt-14 grid gap-5 md:grid-cols-2">
          <DetailCard
            title="Shortcuts, shown as you press them"
            body="A keystroke pill shows ⌘ shortcuts on screen, so tutorials never say “and then I pressed something”."
          >
            <div className={`absolute inset-6 rounded-2xl ${MINI_WALL} opacity-90`} />
            <div className="relative flex gap-1.5 rounded-2xl bg-black/75 px-3 py-2.5 shadow-xl backdrop-blur">
              {["⌘", "⇧", "5"].map((k) => (
                <span
                  key={k}
                  className="inline-flex h-10 min-w-10 items-center justify-center rounded-lg bg-white/12 px-2 text-lg font-medium text-white ring-1 ring-white/15"
                >
                  {k}
                </span>
              ))}
            </div>
          </DetailCard>

          <DetailCard
            title="Private things stay private"
            body="Blur or pixelate an email, a key or a customer's name. Feathered edges, animated over time, dragged right on the preview."
          >
            <div className="relative w-[78%] space-y-2.5 rounded-2xl bg-white p-5 shadow-[0_18px_40px_-24px_rgb(0_0_0/0.4)] ring-1 ring-black/5">
              <div className="h-2.5 w-24 rounded-full bg-black/10" />
              <div className="flex items-center gap-2">
                <span className="text-[13px] text-[var(--cc-air-muted)]">API key</span>
                <span className="relative inline-flex h-6 flex-1 items-center overflow-hidden rounded-md bg-[var(--cc-air-tint)] px-2 font-mono text-[12px] text-[var(--cc-air-ink)]">
                  <span className="blur-[5px]">sk_live_51Hq8xY2eZvKYlo2C9</span>
                </span>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-[13px] text-[var(--cc-air-muted)]">Email</span>
                <span
                  className="inline-flex h-6 flex-1 rounded-md"
                  style={{
                    backgroundImage:
                      "repeating-conic-gradient(#c9c3e8 0% 25%, #e7e3f7 0% 50%), linear-gradient(#000,#000)",
                    backgroundSize: "8px 8px",
                  }}
                />
              </div>
              <div className="h-2.5 w-40 rounded-full bg-black/[0.06]" />
            </div>
          </DetailCard>

          <DetailCard
            title="One recording, every shape"
            body="16:9 for the docs, 9:16 for the feed, 1:1 for the tweet. Change the aspect ratio after recording and the zooms come along."
          >
            <div className="relative flex items-end gap-3">
              {[
                ["w-40 h-[90px]", "16:9"],
                ["w-[66px] h-[118px]", "9:16"],
                ["w-[92px] h-[92px]", "1:1"],
              ].map(([size, label]) => (
                <div key={label} className="flex flex-col items-center gap-2">
                  <div className={`${size} rounded-xl ${MINI_WALL} p-2 shadow-[0_14px_30px_-18px_rgb(40_20_120/0.6)]`}>
                    <div className="h-full w-full rounded-md bg-white/95" />
                  </div>
                  <span className="text-[12px] font-medium text-[var(--cc-air-muted)]">{label}</span>
                </div>
              ))}
            </div>
          </DetailCard>

          <DetailCard
            title="Depth when you want it"
            body="Tilt the screen in 3D, add motion blur and background parallax. A one-click Showcase move makes a flat recording feel filmed."
          >
            <div className={`absolute inset-6 rounded-2xl ${MINI_WALL}`} />
            <div className="relative [perspective:700px]">
              <div className="h-32 w-52 rounded-xl bg-white shadow-[0_30px_50px_-20px_rgb(0_0_0/0.55)] [transform:rotateX(14deg)_rotateY(-20deg)_rotateZ(2deg)]">
                <div className="flex gap-1 p-2.5">
                  <i className="h-2 w-2 rounded-full bg-[#ff5f57]" />
                  <i className="h-2 w-2 rounded-full bg-[#febc2e]" />
                  <i className="h-2 w-2 rounded-full bg-[#28c840]" />
                </div>
                <div className="mx-3 h-2 w-24 rounded-full bg-black/10" />
                <div className="mx-3 mt-2 h-2 w-32 rounded-full bg-black/[0.06]" />
                <div className="mx-3 mt-4 h-7 w-20 rounded-md bg-[#2f7bff]" />
              </div>
            </div>
          </DetailCard>
        </div>
      </AirContainer>
    </section>
  );
}

// ── The statement that fills in as you scroll ───────────────────────────────

const STATEMENT =
  "What you see in the preview is exactly what you get in the file. Every zoom, every cursor glide, every caption, frame for frame.";

export function Statement() {
  const ref = useRef<HTMLParagraphElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      el.style.setProperty("--p", "1");
      return;
    }
    let frame = 0;
    const update = () => {
      frame = 0;
      const r = el.getBoundingClientRect();
      const vh = window.innerHeight;
      // 0 when the top reaches 85 % of the viewport, 1 when the bottom passes 45 %.
      const p = (vh * 0.85 - r.top) / (r.height + vh * 0.4);
      el.style.setProperty("--p", String(Math.min(1, Math.max(0, p))));
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(update);
    };
    update();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);
  const words = STATEMENT.split(" ");
  return (
    <section className="py-24 md:py-36">
      <AirContainer>
        <div className="mx-auto max-w-4xl">
          <AirPill icon={<Sparkles className="h-3.5 w-3.5" strokeWidth={2} />}>The promise</AirPill>
          <p
            ref={ref}
            className="air-reveal mt-6 text-balance text-[32px] font-semibold leading-[1.15] tracking-[-0.035em] text-[var(--cc-air-ink)] md:text-[52px]"
            style={{ ["--n" as string]: words.length }}
          >
            {words.map((w, i) => (
              <span key={i} data-w="" style={{ ["--i" as string]: i }}>
                {w}{" "}
              </span>
            ))}
          </p>
          <p className="mt-6 max-w-xl text-[15px] leading-relaxed text-[var(--cc-air-muted)]">
            The preview and the encoder share one set of maths, and every release is checked frame by frame
            against reference renders.
          </p>
        </div>
      </AirContainer>
    </section>
  );
}

// ── Dark band: agents ──────────────────────────────────────────────────────

export function AgentsBand() {
  return (
    <section
      data-air-dark
      className="relative isolate overflow-hidden bg-[linear-gradient(180deg,#0b0b18_0%,#101a3a_100%)] py-24 md:py-32"
    >
      <div
        aria-hidden
        className="absolute inset-0 -z-10 bg-[radial-gradient(50%_60%_at_80%_0%,rgb(47_123_255/0.25),transparent_70%),radial-gradient(40%_50%_at_10%_100%,rgb(124_92_240/0.25),transparent_70%)]"
      />
      <AirContainer>
        <div className="grid items-center gap-12 md:grid-cols-12">
          <div className="scroll-reveal md:col-span-5">
            <AirPill dark icon={<Bot className="h-3.5 w-3.5" strokeWidth={2} />}>
              AI agents
            </AirPill>
            <AirTitle dark className="mt-5">
              Ask your agent{" "}
              <span className="text-white/45">to edit the video.</span>
            </AirTitle>
            <AirLede dark className="mt-5">
              CaptureCat is its own MCP server. Claude, Codex, Cursor, VS Code or Windsurf can record, search your
              captures, add zooms, blurs and captions in one undoable batch, then look at the frames they made.
            </AirLede>
            <div className="mt-8">
              <InkLink to="/agents" light>
                How agents use CaptureCat
              </InkLink>
            </div>
          </div>
          <div className="scroll-reveal md:col-span-7">
            <AgentSessionDemo />
          </div>
        </div>
      </AirContainer>
    </section>
  );
}

// ── Hairline grid ───────────────────────────────────────────────────────────

const GRID = [
  { icon: Smartphone, title: "iPhone and iPad", body: "Record over USB, framed in a photoreal bezel." },
  { icon: Globe, title: "Web pages by URL", body: "Any viewport, full height, cookie banners stripped." },
  { icon: Gauge, title: "4K at 60 fps", body: "MP4 or MOV, plus looping GIFs." },
  { icon: Scissors, title: "Trim, cut and speed up", body: "Five lanes, snapping, and full undo." },
  { icon: Keyboard, title: "Keystrokes and sounds", body: "A shortcut pill, Thock and Typewriter keys." },
  { icon: ShieldCheck, title: "Blur and spotlight", body: "Hide what's private, dim what's not the point." },
  { icon: ScanSearch, title: "Search inside videos", body: "⌘K reads the text in your recordings, on device." },
  { icon: Layers, title: "Your own storage", body: "Share from your S3, R2, B2, Wasabi or MinIO bucket." },
  { icon: Monitor, title: "Native, no Electron", body: "Swift and Metal. Recording 4K costs less than a tab." },
] as const;

export function FeatureGrid() {
  return (
    <section className="border-t border-[var(--cc-air-hairline)] bg-white py-24 md:py-32">
      <AirContainer>
        <div className="scroll-reveal flex flex-col items-start justify-between gap-6 md:flex-row md:items-end">
          <AirTitle className="max-w-xl">
            And the rest of the toolbox.
          </AirTitle>
          <Link
            to="/features"
            className="text-[15px] font-medium text-[var(--cc-air-ink-2)] underline-offset-4 hover:underline"
          >
            Every feature →
          </Link>
        </div>
        <div className="mt-14 grid grid-cols-1 border-l border-t border-[var(--cc-air-hairline)] sm:grid-cols-2 lg:grid-cols-3">
          {GRID.map((g) => (
            <div key={g.title} className="border-b border-r border-[var(--cc-air-hairline)] p-7 md:p-8">
              <g.icon className="h-5 w-5 text-[var(--cc-air-violet)]" strokeWidth={1.75} />
              <h3 className="mt-5 text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{g.title}</h3>
              <p className="mt-1.5 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{g.body}</p>
            </div>
          ))}
        </div>
      </AirContainer>
    </section>
  );
}

// ── FAQ ─────────────────────────────────────────────────────────────────────

export { AirFaq } from "./Faq";

// ── Closing band ────────────────────────────────────────────────────────────

export function AirFinalCta({
  title = "Your next recording edits itself.",
  lede = "Free for personal use, open source, and no account needed on the Mac.",
  secondary,
}: {
  title?: ReactNode;
  lede?: ReactNode;
  /** Replaces the "Read the source" link. */
  secondary?: ReactNode;
}) {
  return (
    <section data-air-dark className="relative isolate overflow-hidden bg-[#0b0b10] py-28 md:py-36">
      <div
        aria-hidden
        className="absolute inset-0 -z-10 bg-[radial-gradient(55%_70%_at_50%_0%,rgb(124_92_240/0.4),transparent_70%),radial-gradient(40%_50%_at_50%_100%,rgb(255_150_120/0.18),transparent_70%)]"
      />
      <AirContainer className="flex flex-col items-center text-center">
        <CaptureCatMark animated className="cc-float h-16 w-16 drop-shadow-[0_12px_40px_rgba(0,0,0,0.55)]" />
        <AirTitle dark className="mt-8 max-w-2xl">
          {title}
        </AirTitle>
        <AirLede dark className="mt-5 max-w-lg">
          {lede}
        </AirLede>
        <div className="mt-9 flex flex-col items-center gap-3 sm:flex-row">
          <InkLink to="/download" light>
            <AppleGlyph />
            Download for Mac
          </InkLink>
          {secondary ?? (
            <a href={GITHUB_URL} target="_blank" rel="noopener" className={GHOST_ON_DARK}>
              <GitHubIcon />
              Read the source
            </a>
          )}
        </div>
      </AirContainer>
    </section>
  );
}
