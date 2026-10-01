/**
 * Small live recreations of the product for the dashboard's empty states —
 * the marketing site's demos, in miniature: instead of "No videos yet" in
 * grey, the page shows what will happen here. Static markup; the motion is
 * in dashboard.css (`.dsh-art--*`), transform and opacity only, paused
 * offscreen, a settled resting frame under reduced motion. Decorative:
 * every one is aria-hidden and the empty state's text says the same thing.
 */
import type { CSSProperties, ReactNode } from "react";

import { cn } from "@/lib/utils";
import { useOffscreenPause } from "./motion";

function Art({ kind, className, children }: { kind: string; className?: string; children: ReactNode }) {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} aria-hidden className={cn("dsh-art", `dsh-art--${kind}`, className)}>
      {children}
    </div>
  );
}

function Lights({ label }: { label?: string }) {
  return (
    <div className="bar">
      <i />
      <i />
      <i />
      {label && <span>{label}</span>}
    </div>
  );
}

/** macOS arrow, tip at the element's top-left. */
function Cursor({ className }: { className?: string }) {
  return (
    <svg className={cn("cursor", className)} viewBox="0 0 28 40">
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

/** Library: a share from the Mac lands at the top, its link is copied. */
export function LibraryArt({ className }: { className?: string }) {
  return (
    <Art kind="library" className={className}>
      <div className="win">
        <Lights label="app.capturecat.so" />
        <span className="a head">Library</span>
        <span className="a search" />
        <div className="a list">
          <div className="row new">
            <span className="thumb" data-t="3" />
            <span className="a title">Launch video</span>
            <span className="a up">
              <i />
            </span>
            <span className="a done">Just now · 0:12</span>
            <span className="chip chip--cyan">Public</span>
            <span className="a views">0</span>
          </div>
          <div className="a rows">
            {[0, 1, 2].map((i) => (
              <div key={i} className="row">
                <span className="thumb" data-t={i} />
                <span className="line" />
                <span className="line" />
              </div>
            ))}
          </div>
        </div>
      </div>
      <div className="toast">
        <b>✓</b> Link copied
      </div>
    </Art>
  );
}

/** Projects: the web editor plays a project and the auto-zoom kicks in. */
export function EditorArt({ className }: { className?: string }) {
  return (
    <Art kind="editor" className={className}>
      <div className="win">
        <Lights label="Launch video" />
        <div className="a canvas">
          <div className="a plane">
            <div className="a card">
              <span className="a side" />
              <span className="a l1" />
              <span className="a l2" />
              <span className="a btn" />
              <Cursor />
            </div>
          </div>
        </div>
        <div className="a tl">
          <span className="a clip" />
          <span className="a zoom">Zoom</span>
          <span className="a head" />
        </div>
      </div>
    </Art>
  );
}

/** Team: teammates arrive, the shared library fills. */
export function TeamArt({ className }: { className?: string }) {
  return (
    <Art kind="team" className={className}>
      <div className="win">
        <Lights label="Team" />
        <div className="a avs">
          <span className="av">MG</span>
          <span className="av">PS</span>
          <span className="av">ML</span>
          <span className="av">+</span>
        </div>
        <span className="a name">Acme Inc</span>
        <span className="a sub">One library for every share</span>
        <div className="row r1">
          <span className="thumb" data-t="1" />
          <span className="line" />
          <span className="chip chip--cyan">Team</span>
        </div>
        <div className="row r2">
          <span className="thumb" data-t="2" />
          <span className="line" />
          <span className="chip chip--cyan">Team</span>
        </div>
      </div>
    </Art>
  );
}

/** Custom domain: the share link moves onto your own domain. */
export function DomainArt({ className }: { className?: string }) {
  return (
    <Art kind="domain" className={className}>
      <div className="win">
        <div className="bar">
          <i />
          <i />
          <i />
        </div>
        <div className="a url">
          <span className="a lock" />
          <span className="from">
            capturecat.so/share/<b>7Kq2fX</b>
          </span>
          <span className="to">
            <b>share.acme.com</b>/7Kq2fX
          </span>
          <span className="chip chip--green ok">Verified</span>
        </div>
        <span className="a video" />
        <span className="a play" />
        <span className="line t1" />
        <span className="line t2" />
        <span className="line t3" />
        <span className="a cta" />
        <span className="a brand">
          <i /> Acme
        </span>
      </div>
    </Art>
  );
}

/** Single sign-on: one press, and you're in the team. */
export function SsoArt({ className }: { className?: string }) {
  return (
    <Art kind="sso" className={className}>
      <div className="win">
        <span className="a logo" />
        <span className="a ttl">Sign in to Acme</span>
        <span className="a field">
          <span>you@acme.com</span>
        </span>
        <span className="a btn">
          Continue with SSO
          <i />
        </span>
        <span className="chip chip--green ok">✓ Joined Acme</span>
      </div>
    </Art>
  );
}

const BARS = [0.92, 0.88, 0.85, 0.8, 0.74, 0.7, 0.66, 0.68, 0.84, 0.86, 0.62, 0.55, 0.5, 0.48, 0.47, 0.45, 0.42, 0.38];

/** Analytics: viewers per moment of a video fill in. */
export function AnalyticsArt({ className }: { className?: string }) {
  return (
    <Art kind="analytics" className={className}>
      <div className="win">
        <Lights />
        <span className="a lab">Watch heatmap</span>
        <span className="chip chip--green">+1 view</span>
        <div className="a plot">
          {BARS.map((h, i) => (
            <i key={i} style={{ "--h": `${h * 100}%`, "--i": i } as CSSProperties} />
          ))}
        </div>
      </div>
    </Art>
  );
}

/** Comments: viewers comment at a moment of the video. */
export function CommentsArt({ className }: { className?: string }) {
  return (
    <Art kind="comments" className={className}>
      <div className="win">
        <Lights label="Share page" />
        <span className="a video" />
        <span className="a scrub">
          <i />
        </span>
        <span className="a mk mk1" />
        <span className="a mk mk2" />
        <span className="a bub b1">
          <i /> Love this zoom
        </span>
        <span className="a bub b2">
          <i /> Can we cut 0:41?
        </span>
      </div>
    </Art>
  );
}

/** Record: pick a source in the bar, press the red key. */
export function RecordArt({ className }: { className?: string }) {
  return (
    <Art kind="record" className={className}>
      <div className="a screen">
        <span className="a appwin" />
        <span className="a frame" />
        <span className="chip chip--red rec">REC 0:03</span>
      </div>
      <div className="a dock">
        <span className="a sel" />
        <span className="a tab t1">Display</span>
        <span className="a tab t2">Window</span>
        <span className="a tab t3">Tab</span>
        <span className="a key">
          <i />
        </span>
      </div>
    </Art>
  );
}
