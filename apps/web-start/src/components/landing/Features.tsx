import {
  Crosshair,
  MousePointer2,
  Captions,
  Frame,
  Wand2,
  Cpu,
  Link2,
  BarChart3,
  MessageSquare,
} from "lucide-react";

import { SpotlightGroup } from "./SpotlightGroup";
import { FEATURE_GROUPS } from "@/lib/feature-inventory";

/**
 * Feature grid + a sticky "how it happens" showcase.
 *
 * Scroll effects are the CSS scroll-timeline utilities in globals.css
 * (`scroll-reveal`, `scroll-parallax-*`) — no JS, and they no-op cleanly on
 * browsers without `animation-timeline` and under prefers-reduced-motion.
 * The visual language is the site's existing liquid glass; nothing new.
 */

const stats = [
  { value: "4K 60fps", label: "export ceiling" },
  { value: "0", label: "timeline edits needed" },
  { value: "1 click", label: "to a share link" },
  { value: "100%", label: "native Swift + Metal" },
];

const steps = [
  {
    title: "Record",
    description:
      "Pick a window, a display, or an area. Camera and mic come along if you want them — every click and keystroke is captured as data, not just pixels.",
  },
  {
    title: "It edits itself",
    description:
      "CaptureCat replays your session and adds the cinematography: it zooms into the field you typed in, smooths the cursor path, and ripples each click.",
  },
  {
    title: "Make it yours",
    description:
      "Drop it on a wallpaper, add padding and shadow, frame it in a photoreal device bezel, place on-device captions wherever you drag them.",
  },
  {
    title: "Share",
    description:
      "Export a file that matches the preview frame-for-frame, or upload and send a link. Then watch views, drop-off, and comments roll in.",
  },
];

const features = [
  {
    title: "Auto-zoom. No editing required.",
    description:
      "CaptureCat follows your cursor and zooms in on every click and keystroke as you record. Your demo looks polished before you even open the editor.",
    example: "Click a form field → smooth 2.4× push-in that settles in ~600 ms.",
    icon: Crosshair,
  },
  {
    title: "A cursor with manners",
    description:
      "Smoothed motion, click ripples, custom pointers, and it never drifts off the pixel it was recorded over.",
    example: "A jittery hand becomes one confident glide.",
    icon: MousePointer2,
  },
  {
    title: "Captions worth reading",
    description:
      "Transcribed on device, styled with presets, placed anywhere you drag them.",
    example: "No audio leaves your Mac — ever.",
    icon: Captions,
  },
  {
    title: "Framing, handled",
    description:
      "Wallpapers, padding, shadows, a photoreal iPhone bezel, and your own logo watermarked in.",
    example: "One recording, framed for the launch tweet and the docs.",
    icon: Frame,
  },
  {
    title: "What you see is what exports",
    description:
      "The preview and the encoder share the same math, verified frame by frame — so the file is never a surprise.",
    example: "The same code computes every zoom in the preview and the export.",
    icon: Wand2,
  },
  {
    title: "Share links, built in",
    description:
      "Upload straight from the app and send a link. Public or private, your call — flip it any time.",
    example: "capturecat.so/share/… — no YouTube upload screen.",
    icon: Link2,
  },
  {
    title: "Know who watched",
    description:
      "Views, where people stopped watching, and what they clicked — per video, in your dashboard.",
    example: "\"80% dropped at 0:42\" tells you exactly what to trim.",
    icon: BarChart3,
  },
  {
    title: "Timestamped comments",
    description:
      "Viewers can leave feedback pinned to the exact second, right on the share page.",
    example: "\"0:31 — this button label is wrong\" beats a vague email.",
    icon: MessageSquare,
  },
  {
    title: "Done before the coffee cools",
    description:
      "Metal-accelerated export means your 4K recording is ready in seconds, not minutes — 3× faster. Native Swift on macOS, no Electron overhead eating your battery.",
    example: "Recording 4K uses less CPU than a browser tab.",
    icon: Cpu,
  },
];

export default function Features() {
  return (
    <section id="features" className="relative isolate py-28">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-10 overflow-hidden"
      >
        <div
          className="scroll-parallax-slow absolute inset-0"
          style={{
            background:
              "radial-gradient(80% 50% at 50% 0%, rgba(120,140,255,0.10), transparent 65%)",
          }}
        />
        <div
          className="scroll-parallax-fast absolute left-[10%] top-[30%] h-96 w-96 rounded-full blur-3xl"
          style={{ background: "rgba(80,220,255,0.06)" }}
        />
        <div
          className="scroll-parallax-fast absolute right-[8%] top-[60%] h-80 w-80 rounded-full blur-3xl"
          style={{ background: "rgba(255,95,158,0.05)" }}
        />
      </div>

      <div className="mx-auto max-w-6xl px-6">
        {/* Fact strip — one quiet line of product truths, not a stats board. */}
        <div className="scroll-reveal flex flex-wrap items-center justify-center gap-x-3 gap-y-2 text-sm text-muted-foreground">
          {stats.map((s, i) => (
            <span key={s.label} className="flex items-center gap-3">
              {i > 0 && <span aria-hidden className="h-1 w-1 rounded-full bg-white/25" />}
              <span>
                <span className="font-medium text-foreground">{s.value}</span> {s.label}
              </span>
            </span>
          ))}
        </div>

        <h2 className="scroll-reveal mt-24 max-w-2xl text-balance text-4xl font-semibold tracking-[-0.03em] text-foreground md:text-5xl">
          The editing is already done
          <span className="text-muted-foreground"> by the time you stop recording.</span>
        </h2>

        {/* Sticky showcase — the visual pins while the steps scroll past it */}
        <div className="mt-14 grid grid-cols-1 gap-10 lg:grid-cols-2 lg:gap-16">
          <div className="order-2 flex flex-col gap-6 lg:order-1">
            {steps.map((step, i) => (
              <article
                key={step.title}
                className="scroll-reveal relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-8 backdrop-blur-2xl"
              >
                <span
                  aria-hidden
                  className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
                />
                <div className="flex items-center gap-3">
                  <span className="inline-flex h-8 w-8 items-center justify-center rounded-full border border-white/12 bg-white/[0.07] text-sm font-medium">
                    {i + 1}
                  </span>
                  <h3 className="text-lg font-medium tracking-[-0.01em] text-foreground">
                    {step.title}
                  </h3>
                </div>
                <p className="mt-3 text-[15px] leading-relaxed text-muted-foreground">
                  {step.description}
                </p>
              </article>
            ))}
          </div>

          <div className="order-1 lg:order-2">
            <div className="lg:sticky lg:top-28">
              <div className="relative overflow-hidden rounded-[28px] border border-white/12 bg-white/[0.04] p-2 shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] backdrop-blur-2xl">
                <span
                  aria-hidden
                  className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
                />
                <div className="relative aspect-[4/3] overflow-hidden rounded-[22px] bg-[#0e0e10]">
                  <div
                    className="absolute inset-0"
                    style={{
                      background:
                        "linear-gradient(160deg, #2fb8ff 0%, #7c5cff 55%, #ff5f9e 100%)",
                    }}
                  />
                </div>
              </div>
              <p className="mt-4 text-center text-sm text-muted-foreground">
                Auto zoom, cursor smoothing, and captions — applied live.
              </p>
            </div>
          </div>
        </div>

        {/* Feature cards — masonry via CSS columns: cards keep their natural
            height and pack top-to-bottom with no grid holes. */}
        <SpotlightGroup className="mt-24 columns-1 gap-4 md:columns-2 lg:columns-3">
          {features.map((feature) => (
            <article
              key={feature.title}
              className="glass-spot scroll-reveal group relative mb-4 break-inside-avoid overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-8 backdrop-blur-2xl transition-colors duration-500 hover:border-white/20 hover:bg-white/[0.075]"
            >
              {/* Specular top edge — the tell of real glass */}
              <span
                aria-hidden
                className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent opacity-70 transition-opacity duration-500 group-hover:opacity-100"
              />
              <div className="inline-flex h-11 w-11 items-center justify-center rounded-2xl border border-white/12 bg-white/[0.07] text-foreground shadow-[inset_0_1px_0_rgba(255,255,255,0.18)]">
                <feature.icon className="h-[18px] w-[18px]" strokeWidth={1.75} />
              </div>
              <h3 className="mt-6 text-lg font-medium tracking-[-0.01em] text-foreground">
                {feature.title}
              </h3>
              <p className="mt-2.5 text-[15px] leading-relaxed text-muted-foreground">
                {feature.description}
              </p>
              <p className="mt-4 border-t border-white/8 pt-3 text-[13px] leading-relaxed text-muted-foreground/80">
                {feature.example}
              </p>
            </article>
          ))}
        </SpotlightGroup>

        {/* The complete inventory — every shipped feature, grouped. Data
            lives in lib/feature-inventory.ts and also renders /index.md. */}
        <h2 className="scroll-reveal mt-28 max-w-2xl text-balance text-4xl font-semibold tracking-[-0.03em] text-foreground md:text-5xl">
          Everything in the box.
          <span className="text-muted-foreground">
            {" "}
            The full feature list of the screen recorder for Mac.
          </span>
        </h2>
        <div className="mt-12 columns-1 gap-4 md:columns-2 lg:columns-3">
          {FEATURE_GROUPS.map((group) => (
            <article
              key={group.title}
              className="scroll-reveal relative mb-4 break-inside-avoid overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-7 backdrop-blur-2xl"
            >
              <span
                aria-hidden
                className="absolute inset-x-7 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
              />
              <h3 className="text-base font-medium tracking-[-0.01em] text-foreground">
                {group.title}
              </h3>
              <ul className="mt-4 space-y-2.5">
                {group.items.map((item) => (
                  <li
                    key={item}
                    className="flex gap-2.5 text-[13.5px] leading-relaxed text-muted-foreground"
                  >
                    <span
                      aria-hidden
                      className="mt-[7px] h-1 w-1 shrink-0 rounded-full bg-cyan-300/60"
                    />
                    {item}
                  </li>
                ))}
              </ul>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}
