/**
 * Building blocks for the home page's product recreations.
 *
 * Everything here is static markup: the motion lives in styles/home.css,
 * keyed off a `data-script` on the nearest demo root, and only ever animates
 * transform and opacity. Sizes are in container-query units (`--u` = one
 * design pixel of the enclosing canvas), so each recreation scales as one
 * picture from 375 px to 1440 px without a single layout-driven animation.
 *
 * Geometry follows the product's defaults (core/model/defaults.ts): a
 * purple-to-blue gradient wallpaper, the recording centred with padding, a
 * rounded card with a soft shadow, the zoom camera moving the CARD plane
 * (cursor and ripples ride it) while the camera bubble and keystroke pill
 * stay put on the canvas, exactly as the exporter composes a frame.
 */
import type { CSSProperties, ReactNode } from "react";

import { superellipsePath } from "@/editor/core/math/cameraStyleMath";

/** The camera bubble's squircle: the exporter's own superellipse (n = 4.5), sampled to a CSS polygon. */
export const SQUIRCLE_CLIP = (() => {
  const pts = superellipsePath({ x: 0, y: 0, width: 100, height: 100 })
    .filter((e) => e.op !== "close")
    .filter((_, i) => i % 4 === 0)
    .map((e) => `${e.pts[0].x.toFixed(2)}% ${e.pts[0].y.toFixed(2)}%`);
  return `polygon(${pts.join(",")})`;
})();

/** The site's glass bezel (same recipe as MediaPlaceholder's frame). */
export function DemoFrame({
  children,
  className = "",
  blur = true,
}: {
  children: ReactNode;
  className?: string;
  /** Backdrop blur is skipped on pinned stages (it would re-blur every scroll frame). */
  blur?: boolean;
}) {
  return (
    <div
      className={`relative rounded-[22px] border border-white/12 bg-white/[0.04] p-1.5 shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] md:rounded-[28px] md:p-2 ${
        blur ? "backdrop-blur-2xl" : ""
      } ${className}`}
    >
      <span
        aria-hidden
        className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
      />
      <div className="relative overflow-hidden rounded-[16px] bg-[#0e0e10] md:rounded-[22px]">{children}</div>
    </div>
  );
}

/** macOS arrow, tip at the element's top-left. */
export function Cursor({ className = "" }: { className?: string }) {
  return (
    <svg className={`ccd-cursor ${className}`} viewBox="0 0 28 40" aria-hidden>
      <path
        d="M2.5 2.5v28.2l7.1-6.5 4.6 10.9 4.9-2.1-4.6-10.6h9.8z"
        fill="#0b0b0c"
        stroke="#fff"
        strokeWidth="2.2"
        strokeLinejoin="round"
      />
    </svg>
  );
}

const TYPED = "Launch video";

/** A plain light-theme app window, the thing being recorded. `typing`
 *  splits the name into per-character spans for the scripts that type it. */
export function FakeApp({ typing = false }: { typing?: boolean }) {
  return (
    <div className="ccd-app">
      <div className="ccd-app-bar">
        <i />
        <i />
        <i />
        <span>Projects</span>
      </div>
      <div className="ccd-app-side">
        <b>Workspace</b>
        <span className="is-on">New project</span>
        <span>Launches</span>
        <span>Tutorials</span>
        <span>Archive</span>
        <b>Teams</b>
        <span>Design</span>
        <span>Growth</span>
      </div>
      <div className="ccd-app-h">New project</div>
      <div className="ccd-app-sub">Everyone in the workspace can see it.</div>

      <div className="ccd-lbl ccd-lbl-name">Project name</div>
      <div className="ccd-field ccd-f-name">
        <span className="ccd-ph">e.g. Onboarding tour</span>
        <span className="ccd-typed">
          {typing
            ? Array.from(TYPED).map((ch, i) => (
                <span key={i} className="ccd-ch" style={{ animationDelay: `${i * 0.09}s` }}>
                  {ch === " " ? "\u00a0" : ch}
                </span>
              ))
            : TYPED}
          {typing && <span className="ccd-caret ccd-caret-end" />}
        </span>
        {typing && <span className="ccd-caret ccd-caret-start" />}
      </div>

      <div className="ccd-lbl ccd-lbl-team">Team</div>
      <div className="ccd-field ccd-f-team">
        Design <span className="ccd-chev">⌄</span>
      </div>

      <div className="ccd-lbl ccd-lbl-date">Due date</div>
      <div className="ccd-field ccd-f-date">Oct 14, 2026</div>

      <div className="ccd-btn">
        Create project
        <span className="ccd-btn-press" />
      </div>

      <div className="ccd-cover">
        <span>Cover</span>
      </div>
      <div className="ccd-lbl ccd-lbl-secret">Webhook secret</div>
      <div className="ccd-field ccd-f-secret">whsec_9f2c1d7a4be0</div>

      <div className="ccd-toast">
        <span>✓</span> Project created
      </div>
    </div>
  );
}

/** The recording, as a card on the canvas: app + ripples + cursor tracks. */
export function Card({ ghosts = false, typing = false }: { ghosts?: boolean; typing?: boolean }) {
  return (
    <div className="ccd-card">
      <FakeApp typing={typing} />
      <span className="ccd-ripple ccd-r1" />
      <span className="ccd-ripple ccd-r2" />
      <span className="ccd-ripple ccd-r3" />
      <span className="ccd-track ccd-track--raw">
        <Cursor />
      </span>
      {ghosts && (
        <>
          <span className="ccd-track ccd-track--main ccd-ghost ccd-ghost-2">
            <Cursor />
          </span>
          <span className="ccd-track ccd-track--main ccd-ghost ccd-ghost-1">
            <Cursor />
          </span>
        </>
      )}
      <span className="ccd-track ccd-track--main">
        <Cursor />
      </span>
    </div>
  );
}

/** One zoomable card plane (shadow + card), wrapped for the camera. */
export function CardPlane({
  blur = false,
  ghosts = false,
  typing = false,
}: {
  blur?: boolean;
  ghosts?: boolean;
  typing?: boolean;
}) {
  return (
    <div className={`ccd-cam ${blur ? "ccd-cam--blur" : ""}`} aria-hidden>
      <div className="ccd-cardwrap">
        <div className="ccd-shadow" />
        <div className="ccd-shadow ccd-shadow--deep" />
        <Card ghosts={ghosts && !blur} typing={typing} />
      </div>
    </div>
  );
}

export function CameraBubble({
  tag = false,
  shape = "squircle",
}: {
  tag?: boolean;
  /** "both" renders circle and squircle so a script can morph between them. */
  shape?: "circle" | "squircle" | "both";
}) {
  return (
    <div className={`ccd-bubble ccd-bubble--${shape}`}>
      {shape !== "squircle" && (
        <div className="ccd-bub-shape ccd-bub-circle">
          <Face />
        </div>
      )}
      {shape !== "circle" && (
        <div className="ccd-bub-shape ccd-bub-squircle" style={{ clipPath: SQUIRCLE_CLIP }}>
          <div className="ccd-bub-ring" style={{ clipPath: SQUIRCLE_CLIP }} />
          <div className="ccd-bub-inner" style={{ clipPath: SQUIRCLE_CLIP }}>
            <Face />
          </div>
        </div>
      )}
      {tag && <div className="ccd-bub-tag">Sam Rivera · Product</div>}
    </div>
  );
}

/** A stylised webcam frame (no photo, no person likeness). */
function Face() {
  return (
    <svg className="ccd-face" viewBox="0 0 100 100" preserveAspectRatio="xMidYMid slice" aria-hidden>
      <defs>
        <linearGradient id="ccdFaceBg" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#3a4a63" />
          <stop offset="1" stopColor="#1f2636" />
        </linearGradient>
        <linearGradient id="ccdFaceSkin" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#f2c6a4" />
          <stop offset="1" stopColor="#d9a07e" />
        </linearGradient>
      </defs>
      <rect width="100" height="100" fill="url(#ccdFaceBg)" />
      <circle cx="78" cy="22" r="26" fill="#ffd9a0" opacity="0.18" />
      <path d="M14 104c2-22 17-34 36-34s34 12 36 34z" fill="#5b7cfa" />
      <path d="M40 66h20v10a10 10 0 0 1-20 0z" fill="#d9a07e" />
      <ellipse cx="50" cy="45" rx="17" ry="20" fill="url(#ccdFaceSkin)" />
      <path d="M32 42c0-14 8-22 18-22 11 0 19 8 18 21-4-7-10-10-18-10s-14 3-18 11z" fill="#2b2320" />
    </svg>
  );
}

export function KeysPill({ keys }: { keys: string[] }) {
  return (
    <div className="ccd-keys">
      {keys.map((k) => (
        <span key={k}>{k}</span>
      ))}
    </div>
  );
}

/** The canvas: wallpaper + card plane (+ optional motion-blur copy) + overlays. */
export function Canvas({
  script,
  motionBlur = false,
  ghosts = false,
  typing = false,
  children,
  className = "",
  style,
}: {
  script: string;
  motionBlur?: boolean;
  ghosts?: boolean;
  /** Per-character typing of the project name (scripts that type it). */
  typing?: boolean;
  children?: ReactNode;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <div className={`ccd-canvas ${className}`} data-script={script} style={style} aria-hidden>
      <div className="ccd-wall" />
      <div className="ccd-wall ccd-wall-b" />
      <div className="ccd-wall ccd-wall-c" />
      <div className="ccd-wall-d" />
      <CardPlane ghosts={ghosts} typing={typing} />
      {motionBlur && <CardPlane blur typing={typing} />}
      {children}
    </div>
  );
}

// ── Timeline ───────────────────────────────────────────────────────────────

export interface TimelineBlock {
  className: string;
  left: number;
  width: number;
  label?: string;
}

export interface TimelineLane {
  name: "VIDEO" | "VOICE" | "EFFECTS" | "FOCUS" | "ANNOTATE";
  blocks?: TimelineBlock[];
}

/** Deterministic waveform heights (no Math.random: SSR and client agree). */
const WAVE = Array.from({ length: 30 }, (_, i) => {
  const v = Math.abs(Math.sin(i * 1.7) * 0.6 + Math.sin(i * 0.43) * 0.4);
  return 18 + Math.round(v * 72);
});

export function Timeline({
  lanes,
  duration,
  className = "",
  clicks = [],
  videoExtras,
}: {
  lanes: TimelineLane[];
  /** Seconds shown on the ruler. */
  duration: number;
  className?: string;
  /** Click markers on the VIDEO lane, as fractions of the track. */
  clicks?: number[];
  /** Extra marks drawn on the VIDEO clip (split line, speed region). */
  videoExtras?: ReactNode;
}) {
  const ticks = Array.from({ length: duration + 1 }, (_, i) => i);
  return (
    <div className={`ccd-tl ${className}`} aria-hidden>
      <div className="ccd-tl-labels">
        <span className="ccd-tl-rulerpad" />
        {lanes.map((l) => (
          <span key={l.name}>{l.name}</span>
        ))}
      </div>
      <div className="ccd-tl-area">
        <div className="ccd-tl-ruler">
          {ticks.map((t) => (
            <span key={t} style={{ left: `${(t / duration) * 100}%` }} data-major={t % 2 === 0 ? "" : undefined}>
              {t % 2 === 0 && t < duration ? <em>{`0:${String(t).padStart(2, "0")}`}</em> : null}
            </span>
          ))}
        </div>
        {lanes.map((l) => (
          <div key={l.name} className="ccd-tl-lane" data-lane={l.name}>
            {l.name === "VIDEO" && (
              <div className="ccd-tl-film">
                <span className="ccd-tl-film-a" />
                <span className="ccd-tl-film-b" />
                {clicks.map((c, i) => (
                  <i key={c} className={`ccd-tl-click ccd-tl-click-${i + 1}`} style={{ left: `${c * 100}%` }} />
                ))}
                {videoExtras}
              </div>
            )}
            {l.name === "VOICE" && (
              <div className="ccd-tl-voice">
                {WAVE.map((h, i) => (
                  <i key={i} style={{ height: `${h}%` }} />
                ))}
              </div>
            )}
            {l.blocks?.map((b) => (
              <div
                key={b.className}
                className={`ccd-tl-block ${b.className}`}
                style={{ left: `${b.left}%`, width: `${b.width}%` }}
              >
                {b.label}
              </div>
            ))}
          </div>
        ))}
        <div className="ccd-tl-head">
          <i />
        </div>
      </div>
    </div>
  );
}

/** Mac editor window: toolbar, the canvas, and the timeline under it. */
export function EditorMock({
  script,
  title,
  lanes,
  duration,
  clicks,
  className = "",
  motionBlur = false,
  overlays,
}: {
  script: string;
  title: string;
  lanes: TimelineLane[];
  duration: number;
  clicks?: number[];
  className?: string;
  motionBlur?: boolean;
  overlays?: ReactNode;
}) {
  return (
    <div className={`ccd-editor ${className}`} data-script={script} aria-hidden>
      <div className="ccd-ed-bar">
        <span className="ccd-lights">
          <i />
          <i />
          <i />
        </span>
        <span className="ccd-ed-title">{title}</span>
        <span className="ccd-ed-keys">
          <span className="ccd-key">Share</span>
          <span className="ccd-key ccd-key--primary">Export</span>
        </span>
      </div>
      <div className="ccd-ed-stage">
        <Canvas script={script} motionBlur={motionBlur} ghosts={motionBlur} typing={script === "hero"}>
          {overlays}
        </Canvas>
      </div>
      <Timeline lanes={lanes} duration={duration} clicks={clicks} />
    </div>
  );
}
