/**
 * The inspector's live preview pads — web twins of the Mac's self-driving
 * demo wells. Each runs on the SAME math the preview and exporter use (the
 * core ports), animates on a visible-only rAF clock that writes straight to
 * the DOM / a canvas (never a React re-render per frame), and keeps the
 * Mac's fixed demo-content colours in both themes (only the pad chrome
 * re-inks).
 *
 *  CursorPreviewBox      CursorPreviewBoxControl (CursorSettingsPaneAppKit)
 *  CameraPreviewPad      CameraPreviewPadControl + CameraSilhouetteLayer
 *  MotionSpeedPad        MotionSpeedPadControl (MotionSettingsPaneAppKit)
 *  TiltPad               TiltPadControl + MiniTiltCardLayer
 *  ZoomFocusPad          ZoomFocusPadControl
 *  EffectPreviewPad      EffectPreviewPadControl (slide / zoom)
 *  PropertyPreviewPad    PropertyPreviewPadControl (parallax / motion blur /
 *                        frame style / highlight mask)
 *  SubtitlePositionPad   SubtitlePositionPadControl
 *  WatermarkPad          WatermarkPositionPadControl
 *  SubtitlePresetCard    SubtitlePresetCardControl
 */
import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";

import type { CameraPosition, CameraShape, CursorEvent, CursorStyle, IntroSlideStyle, ProjectSettings } from "../../core/model";
import type { SubtitlePreset } from "../../core/model/helpers";
import { asset as cursorAsset, artwork as cursorArtwork } from "../../core/math/cursorStyleProvider";
import { simulate as springSimulate } from "../../core/math/cursorSpringMath";
import { interpolate as smootherInterpolate } from "../../core/math/cursorSmoother";
import * as IntroSlideMath from "../../core/math/introSlideMath";
import { caTransform3DArray, perspectiveDistance, projectionTransform } from "../../core/math/tiltMath";
import { fraction as cameraCornerFraction } from "../../core/math/reactiveCameraLayout";
import { formatFixed, sInt, srounded } from "../../core/math/swift";
import { SFIcon } from "../kit";
import { toRGBA, useDrag, useFrameLoop } from "./shared";

const css = (c: { r: number; g: number; b: number; a: number }, alpha = c.a) =>
  `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${alpha})`;

/** Element size in CSS px (the Mac `bounds`, border included). */
function useSize<T extends HTMLElement>(ref: React.RefObject<T | null>) {
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setSize({ w: el.offsetWidth, h: el.offsetHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref]);
  return size;
}

// ── Cursor preview box ──────────────────────────────────────────────────

const LOOP = 3.0;
const RIPPLE = 0.45;

const spriteCache = new Map<string, HTMLCanvasElement>();
let handImage: HTMLImageElement | null = null;

/** `NSCursor.pointingHand` stand-in (the system raster isn't shippable). */
function loadHand() {
  if (handImage || typeof Image === "undefined") return;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 32 32">` +
    `<path d="M11.5 27 L8 21.5 C7 20 7.3 18.6 8.6 18.4 C9.6 18.2 10.4 18.9 11 19.8 L12 21.2 L12 8.5 C12 7.2 12.9 6.3 14 6.3 C15.1 6.3 16 7.2 16 8.5 L16 14.5 L16.3 14.5 C16.3 13.4 17.2 12.7 18.1 12.7 C19 12.7 19.8 13.4 19.8 14.5 L19.9 15 C20 14.1 20.8 13.5 21.7 13.6 C22.6 13.7 23.3 14.4 23.3 15.4 L23.4 16.1 C23.6 15.4 24.3 14.9 25.1 15 C25.9 15.1 26.5 15.8 26.5 16.8 L26.5 21.5 C26.5 24.5 25 27 23.5 27 Z" fill="#fff" stroke="#000" stroke-width="1.4" stroke-linejoin="round"/>` +
    `</svg>`;
  const img = new Image();
  img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  handImage = img;
}

/** The cursor sprite at `scale` × dpr, drawn from the core artwork ops. */
function cursorSprite(style: CursorStyle, scale: number, dpr: number): HTMLCanvasElement | null {
  const key = `${style}|${scale}|${dpr}`;
  const hit = spriteCache.get(key);
  if (hit) return hit;
  const a = cursorAsset(style);
  const art = cursorArtwork(style);
  const k = scale * dpr;
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.ceil(a.imageSize.width * k));
  c.height = Math.max(1, Math.ceil(a.imageSize.height * k));
  const ctx = c.getContext("2d");
  if (!ctx) return null;
  ctx.scale(k, k);
  if (!art) {
    loadHand();
    if (!handImage?.complete || !handImage.naturalWidth) return null;
    ctx.drawImage(handImage, 0, 0, a.imageSize.width, a.imageSize.height);
  } else {
    for (const op of art.ops) {
      const color = css(op.color);
      if (op.kind === "strokePath" || op.kind === "fillPath") {
        ctx.beginPath();
        op.points.forEach((p, i) => (i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)));
        ctx.closePath();
        if (op.kind === "strokePath") {
          ctx.lineJoin = "round";
          ctx.lineWidth = op.lineWidth;
          ctx.strokeStyle = color;
          ctx.stroke();
        } else {
          ctx.fillStyle = color;
          ctx.fill("nonzero");
        }
      } else {
        const r = op.rect;
        ctx.beginPath();
        ctx.ellipse(r.x + r.width / 2, r.y + r.height / 2, r.width / 2, r.height / 2, 0, 0, Math.PI * 2);
        if (op.kind === "strokeOval") {
          ctx.lineWidth = op.lineWidth;
          ctx.strokeStyle = color;
          ctx.stroke();
        } else {
          ctx.fillStyle = color;
          ctx.fill();
        }
      }
    }
  }
  spriteCache.set(key, c);
  return c;
}

/** Looping live preview of the cursor treatment: glide (the REAL
 *  CursorSpringMath when fluid is on), click ripple, auto-hide fade,
 *  loop-to-start / stop-at-end. */
export function CursorPreviewBox({ s }: { s: ProjectSettings }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const sRef = useRef(s);
  sRef.current = s;
  const spring = useRef<{ sig: string; path: CursorEvent[] } | null>(null);

  useFrameLoop(boxRef, (now) => {
    const box = boxRef.current;
    const canvas = canvasRef.current;
    if (!box || !canvas) return;
    const w = box.offsetWidth;
    const h = box.offsetHeight;
    if (w < 2) return;
    const dpr = window.devicePixelRatio || 1;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const st = sRef.current;
    const smoothing = st.smoothCursor ? st.smoothingFactor : 0;
    const t = now % LOOP;
    const glideDuration = 0.7 + smoothing * 2.2;
    const p = Math.min(1, t / glideDuration);
    const eased = p * p * (3 - 2 * p);
    const start = { x: w * 0.22, y: h * 0.62 };
    const end = { x: w * 0.68, y: h * 0.44 };
    let pos: { x: number; y: number };
    if (st.cursorFluidEnabled) {
      const sig = `${st.cursorTension}:${st.cursorFriction}:${st.cursorMass}:${sInt(w)}x${sInt(h)}`;
      if (spring.current?.sig !== sig) {
        const raw: CursorEvent[] = [
          { timestamp: 0, x: start.x, y: start.y, isClick: false },
          { timestamp: 0.45, x: start.x, y: start.y, isClick: false },
          { timestamp: 0.8, x: end.x, y: end.y, isClick: false },
          { timestamp: LOOP, x: end.x, y: end.y, isClick: false },
        ];
        spring.current = { sig, path: springSimulate(raw, st.cursorTension, st.cursorFriction, st.cursorMass) };
      }
      pos = smootherInterpolate(spring.current.path, t);
    } else {
      pos = { x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased };
    }
    const clickTime = glideDuration + 0.25;
    const rp = (t - clickTime) / RIPPLE;
    let opacity = 1;
    if (st.autoHideCursor) {
      const fadeStart = LOOP - 0.5;
      opacity = t > fadeStart ? Math.max(0, 1 - (t - fadeStart) / 0.4) : 1;
    }
    const endPos = { ...pos };
    if (st.cursorLoopToStart) {
      const rampStart = LOOP - 0.8;
      if (t > rampStart) {
        const q = Math.min(1, Math.max(0, (t - rampStart) / 0.8));
        const e = q * q * (3 - 2 * q);
        endPos.x += (start.x - endPos.x) * e;
        endPos.y += (start.y - endPos.y) * e;
      }
    } else if (st.cursorStopAtEnd && t > LOOP - 0.5) {
      endPos.x = end.x;
      endPos.y = end.y;
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    if (st.showCursor) {
      const a = cursorAsset(st.cursorStyle);
      const sprite = cursorSprite(st.cursorStyle, st.cursorScale, dpr);
      if (sprite) {
        ctx.save();
        ctx.globalAlpha = opacity;
        ctx.shadowColor = "rgba(0,0,0,0.4)";
        ctx.shadowBlur = 1.5 * dpr;
        ctx.shadowOffsetX = 0.5 * dpr;
        ctx.shadowOffsetY = 1 * dpr;
        ctx.drawImage(
          sprite,
          endPos.x - a.hotSpot.x * st.cursorScale,
          endPos.y - a.hotSpot.y * st.cursorScale,
          a.imageSize.width * st.cursorScale,
          a.imageSize.height * st.cursorScale,
        );
        ctx.restore();
      }
    }
    if (st.showClickRipple && rp >= 0 && rp <= 1) {
      const c = toRGBA(st.clickRippleColor);
      const size = st.clickRippleSize;
      const outerD = size * (0.2 + rp * 0.8);
      const outerOpacity = 1 - rp;
      const g = ctx.createRadialGradient(end.x, end.y, 0, end.x, end.y, outerD / 2);
      g.addColorStop(0, css(c, c.a * outerOpacity * 0.12));
      g.addColorStop(1, css(c, 0));
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(end.x, end.y, outerD / 2, 0, Math.PI * 2);
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = css(c, outerOpacity * 0.7);
      ctx.beginPath();
      ctx.arc(end.x, end.y, outerD / 2, 0, Math.PI * 2);
      ctx.stroke();
      const ip = Math.max(0, rp - 0.1) / 0.9;
      const innerD = size * 0.6 * (0.15 + ip * 0.5);
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = css(c, Math.max(0, 1 - ip * 1.5) * 0.5);
      ctx.beginPath();
      ctx.arc(end.x, end.y, innerD / 2, 0, Math.PI * 2);
      ctx.stroke();
      ctx.fillStyle = css(c, Math.max(0, 1 - rp * 3) * 0.6);
      ctx.beginPath();
      ctx.arc(end.x, end.y, 3, 0, Math.PI * 2);
      ctx.fill();
    }
  });

  return (
    <div ref={boxRef} className="cc-livepad cc-livepad--ink" style={{ height: 110 }} aria-hidden>
      {[0, 1, 2].map((i) => (
        <span key={i} className="cc-livepad__abs" style={{ left: 10 + i * 9, top: 10, width: 5, height: 5, borderRadius: 2.5, background: "rgb(255 255 255 / 0.18)" }} />
      ))}
      {[
        [0.4, 0.12],
        [0.62, 0.08],
        [0.5, 0.08],
      ].map(([wf, alpha], i) => (
        <span key={`l${i}`} className="cc-livepad__abs" style={{ left: 10, top: 24 + i * 10, width: `${wf * 100}%`, height: 5, borderRadius: 2, background: `rgb(255 255 255 / ${alpha})` }} />
      ))}
      <canvas ref={canvasRef} className="cc-livepad__canvas" />
    </div>
  );
}

// ── Camera preview pad ──────────────────────────────────────────────────

/** Mini canvas: bubble placement, shape and relative size with the animated
 *  silhouette. Drag places freely (cameraCustomX/Y); a release within 0.08
 *  of a corner collapses back to the corner enum. */
export function CameraPreviewPad({
  s,
  dimmed,
  onPlace,
  onSnap,
}: {
  s: ProjectSettings;
  dimmed: boolean;
  onPlace: (x: number, y: number) => void;
  onSnap: (corner: CameraPosition) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const shoulders = useRef<HTMLSpanElement>(null);
  const head = useRef<HTMLSpanElement>(null);
  const size = useSize(ref);
  const inset = 8;
  const effective = Math.max(120, s.cameraSize);
  const bubble = 20 + ((effective - 120) / 200) * 26;
  const f = s.cameraCustomX != null && s.cameraCustomY != null ? { x: s.cameraCustomX, y: s.cameraCustomY } : cameraCornerFraction(s.cameraPosition);
  const cx = inset + bubble / 2 + (size.w - bubble - 2 * inset) * f.x;
  const cy = inset + bubble / 2 + (size.h - bubble - 2 * inset) * f.y;
  const radius = shapeRadius(s.cameraShape, bubble);
  const latest = useRef({ x: f.x, y: f.y, custom: s.cameraCustomX != null && s.cameraCustomY != null });
  latest.current = { x: f.x, y: f.y, custom: s.cameraCustomX != null && s.cameraCustomY != null };

  const drag = useDrag(
    (x, y, el) => {
      const w = el.offsetWidth;
      const h = el.offsetHeight;
      const fx = (x + 1 - inset - bubble / 2) / Math.max(1, w - bubble - 2 * inset);
      const fy = (y + 1 - inset - bubble / 2) / Math.max(1, h - bubble - 2 * inset);
      const nx = Math.min(1, Math.max(0, fx));
      const ny = Math.min(1, Math.max(0, fy));
      latest.current = { x: nx, y: ny, custom: true };
      onPlace(nx, ny);
    },
    () => {
      const { x, y, custom } = latest.current;
      if (!custom) return;
      for (const corner of ["Top Left", "Top Right", "Bottom Left", "Bottom Right"] as CameraPosition[]) {
        const c = cameraCornerFraction(corner);
        if (Math.abs(c.x - x) < 0.08 && Math.abs(c.y - y) < 0.08) {
          onSnap(corner);
          return;
        }
      }
    },
  );

  const mirrored = s.cameraMirrored;
  useFrameLoop(ref, (t) => {
    const sh = shoulders.current;
    const hd = head.current;
    if (!sh || !hd) return;
    const breathe = 1 + 0.028 * Math.sin(t * 1.15);
    const nod = 2.6 * Math.sin(t * 0.85) + 1.4 * Math.sin(t * 2.05 + 0.7);
    const glance = bubble * 0.028 * Math.sin(t * 0.45 + 2.1);
    const sway = bubble * 0.015 * Math.sin(t * 0.7 + 1.0);
    sh.style.transform = `translateX(${sway}px) scaleY(${breathe})`;
    hd.style.transform = `translateX(${sway + glance}px) rotate(${nod}deg)`;
  });

  const shoulderW = bubble * 0.92;
  const shoulderH = bubble * 0.55;
  const headSize = bubble * 0.38;
  return (
    <div
      ref={ref}
      className="cc-livepad cc-livepad--ink"
      style={{ height: 96, opacity: dimmed ? 0.45 : 1, cursor: "default" }}
      role="presentation"
      {...drag}
    >
      <span className="cc-livepad__abs cc-livepad__faux" style={{ left: 10, top: 10, width: "34%", height: 4, opacity: 0.1 }} />
      <span className="cc-livepad__abs cc-livepad__faux" style={{ left: 10, top: 18, width: "50%", height: 4, opacity: 0.07 }} />
      {size.w > 0 && (
        <span
          className="cc-livepad__abs cc-campad__bubble"
          style={{ left: cx - bubble / 2 - 1, top: cy - bubble / 2 - 1, width: bubble, height: bubble, borderRadius: radius }}
        >
          <span className="cc-campad__sil" style={{ transform: mirrored ? "scaleX(-1)" : undefined }}>
            <span
              ref={shoulders}
              className="cc-campad__part"
              style={{ width: shoulderW, height: shoulderH, borderRadius: shoulderH / 2, left: (bubble - shoulderW) / 2, top: bubble / 2 + bubble * 0.45 - shoulderH / 2 - shoulderH / 2, transformOrigin: "50% 100%" }}
            />
            <span
              ref={head}
              className="cc-campad__part"
              style={{ width: headSize, height: headSize, borderRadius: headSize / 2, left: (bubble - headSize) / 2, top: bubble / 2 + bubble * 0.04 - headSize / 2, transformOrigin: "50% 100%" }}
            />
          </span>
        </span>
      )}
    </div>
  );
}

function shapeRadius(shape: CameraShape, bubble: number) {
  switch (shape) {
    case "Circle":
      return bubble / 2;
    case "Squircle":
      return (bubble / 2) * 0.6;
    case "Rounded Rectangle":
      return (bubble / 2) * 0.35;
    case "Square":
      return 0;
  }
}

// ── Motion speed pad ────────────────────────────────────────────────────

/** Loops a zoom-in / release on the EXACT spring the preview and exporter
 *  use (ω = 2.5/duration, ζ = 0.88). */
export function MotionSpeedPad({ duration }: { duration: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLSpanElement>(null);
  const d = useRef(duration);
  d.current = duration;
  useFrameLoop(ref, (now) => {
    const el = card.current;
    if (!el) return;
    const animDur = Math.max(0.2, d.current);
    const cycle = Math.max(2.4, animDur * 2 + 1.2);
    const t = now % cycle;
    const half = cycle / 2;
    const resp = (u: number) => {
      if (!(u > 0)) return 0;
      const omega = 2.5 / animDur;
      const zeta = 0.88;
      const damped = omega * Math.sqrt(1 - zeta * zeta);
      return 1 - Math.exp(-zeta * omega * u) * (Math.cos(damped * u) + ((zeta * omega) / damped) * Math.sin(damped * u));
    };
    const zoom = t < half ? 1 + 0.5 * resp(t - 0.2) : 1 + 0.5 * (1 - resp(t - half - 0.2));
    el.style.transform = `scale(${zoom})`;
  });
  return (
    <div ref={ref} className="cc-livepad cc-livepad--ink" style={{ height: 84 }} aria-hidden>
      <span ref={card} className="cc-livepad__abs cc-speedpad__card">
        {[0, 1, 2].map((i) => (
          <span key={i} className="cc-livepad__abs cc-speedpad__ink" style={{ left: 8 + i * 7, top: 8, width: 4, height: 4, borderRadius: 2, opacity: 0.28 }} />
        ))}
        {[30, 46, 38].map((w, i) => (
          <span key={`l${i}`} className="cc-livepad__abs cc-speedpad__ink" style={{ left: 8, top: 18 + i * 7.5, width: w, height: 3.5, borderRadius: 1.5, opacity: 0.16 }} />
        ))}
      </span>
    </div>
  );
}

// ── Title + value pill (Skew / Focus / Offset headers) ──────────────────

function PadHeader({ title, value }: { title: string; value: string }) {
  return (
    <div className="cc-padhead">
      <span className="cc-padhead__title">{title}</span>
      <span className="cc-padhead__pill">{value}</span>
    </div>
  );
}

// ── Tilt pad ────────────────────────────────────────────────────────────

const MINI_CARD = { width: 64, height: 40 };

/** 2D skew pad: drag sets yaw (x) + pitch (y), the mini card warps with the
 *  REAL TiltMath homography; double-click resets. */
export function TiltPad({
  pitch,
  yaw,
  roll,
  maxAngle = 60,
  onChange,
  onCommit,
}: {
  pitch: number;
  yaw: number;
  roll: number;
  maxAngle?: number;
  onChange: (pitch: number, yaw: number) => void;
  onCommit?: () => void;
}) {
  const drag = useDrag(
    (x, y, el) => {
      const w = el.offsetWidth;
      const h = el.offsetHeight;
      const fx = (x + 1 - w / 2) / Math.max(1, w / 2 - 10);
      const fy = (h / 2 - (y + 1)) / Math.max(1, h / 2 - 10);
      onChange(srounded(Math.max(-1, Math.min(1, fy)) * maxAngle), srounded(Math.max(-1, Math.min(1, fx)) * maxAngle));
    },
    onCommit,
  );
  const matrix = useMemo(() => {
    const p = projectionTransform(pitch, yaw, roll, { x: 0, y: 0 }, perspectiveDistance(MINI_CARD));
    return `matrix3d(${caTransform3DArray(p).join(",")})`;
  }, [pitch, yaw, roll]);
  const kx = 0.5 + (yaw / maxAngle) * 0.5;
  const ky = 0.5 - (pitch / maxAngle) * 0.5;
  return (
    <div className="cc-tiltpad">
      <PadHeader title="Skew" value={`${formatFixed(pitch, 0)}° / ${formatFixed(yaw, 0)}°`} />
      <div
        className="cc-tiltpad__area cc-livepad--ink"
        {...drag}
        onDoubleClick={() => {
          onChange(0, 0);
          onCommit?.();
        }}
      >
        <span className="cc-livepad__abs cc-tiltpad__cross" style={{ left: "calc(50% - 1px)", top: 5, width: 1, bottom: 5 }} />
        <span className="cc-livepad__abs cc-tiltpad__cross" style={{ top: "calc(50% - 1px)", left: 5, height: 1, right: 5 }} />
        <span className="cc-livepad__abs cc-tiltpad__card" style={{ transform: matrix }}>
          {[26, 40, 34].map((w, i) => (
            <span key={i} className="cc-livepad__abs" style={{ left: 6, top: 6 + i * 6, width: w, height: 3, borderRadius: 1, background: `rgb(0 0 0 / ${i === 0 ? 0.25 : 0.15})` }} />
          ))}
        </span>
        <span
          className="cc-livepad__abs cc-tiltpad__knob"
          style={{ left: `calc(50% - 7px + (${kx} - 0.5) * (100% - 20px))`, top: `calc(50% - 7px + (${ky} - 0.5) * (100% - 20px))` }}
        />
      </div>
    </div>
  );
}

// ── Zoom focus / offset pad ─────────────────────────────────────────────

export function ZoomFocusPad({
  title = "Focus",
  focal,
  onChange,
  onCommit,
}: {
  title?: string;
  focal: { x: number; y: number };
  onChange: (p: { x: number; y: number }) => void;
  onCommit?: () => void;
}) {
  const drag = useDrag((x, y, el) => {
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    onChange({ x: Math.min(1, Math.max(0, (x + 1) / w)), y: Math.min(1, Math.max(0, (y + 1) / h)) });
  }, onCommit);
  const pct = (v: number) => sInt(srounded(v * 100));
  return (
    <div className="cc-focuspad">
      <PadHeader title={title} value={`${pct(focal.x)}% / ${pct(focal.y)}%`} />
      <div className="cc-focuspad__area cc-livepad--ink" {...drag}>
        {[1 / 3, 2 / 3].map((f) => (
          <span key={`v${f}`} className="cc-livepad__abs cc-focuspad__third" style={{ left: `calc(${f * 100}% - 1px)`, top: 3, bottom: 3, width: 1 }} />
        ))}
        {[1 / 3, 2 / 3].map((f) => (
          <span key={`h${f}`} className="cc-livepad__abs cc-focuspad__third" style={{ top: `calc(${f * 100}% - 1px)`, left: 3, right: 3, height: 1 }} />
        ))}
        <span className="cc-livepad__abs cc-focuspad__ring" style={{ left: `calc(${focal.x * 100}% - 9px)`, top: `calc(${focal.y * 100}% - 9px)` }} />
        <span className="cc-livepad__abs cc-focuspad__dot" style={{ left: `calc(${focal.x * 100}% - 5.5px)`, top: `calc(${focal.y * 100}% - 5.5px)` }} />
      </div>
    </div>
  );
}

// ── Effect preview pad (slide / zoom) ───────────────────────────────────

export type EffectPadMode =
  | { kind: "slide"; style: IntroSlideStyle; duration: number; bounce: number; depth: boolean }
  | { kind: "zoom"; level: number; omegaMultiplier: number; damping: number };

export function EffectPreviewPad({ mode }: { mode: EffectPadMode }) {
  const ref = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLSpanElement>(null);
  const modeRef = useRef(mode);
  const loop = useRef({ start: 0, last: 0, zoom: 1, vel: 0, sig: "" });
  modeRef.current = mode;
  const sig = JSON.stringify(mode);
  if (loop.current.sig !== sig) {
    // `mode didSet → restartLoop()`
    const now = typeof performance !== "undefined" ? performance.now() / 1000 : 0;
    loop.current = { start: now, last: now, zoom: 1, vel: 0, sig };
  }
  useFrameLoop(ref, (now) => {
    const el = card.current;
    const box = ref.current;
    if (!el || !box) return;
    const w = box.offsetWidth;
    const h = box.offsetHeight;
    const m = modeRef.current;
    const L = loop.current;
    if (m.kind === "slide") {
      const cycle = 0.2 + m.duration + 0.8;
      const t = ((now - L.start) % cycle) - 0.2;
      const state = IntroSlideMath.state(m.style, Math.max(t, -0.001), 0, m.duration, m.bounce, m.depth);
      const ox = Math.max(-1.2, Math.min(1.2, state.offset.x)) * w;
      const oy = Math.max(-1.2, Math.min(1.2, state.offset.y)) * h;
      const s = t < 0 ? (m.depth ? IntroSlideMath.depthStartScale : IntroSlideMath.startScale) : state.scale;
      const tip = Math.abs(state.pitch) > 0.01 ? `perspective(640px) rotateX(${-state.pitch}deg) ` : "";
      el.style.transform = `translate(${ox}px, ${oy}px) ${tip}scale(${s})`;
    } else {
      const cycle = 3.2;
      const phase = (now - L.start) % cycle;
      const target = phase < 1.6 ? Math.max(0.3, Math.min(2.2, m.level)) : 1;
      const dt = Math.min(0.05, Math.max(0, now - L.last));
      const omega = (2.5 / 0.8) * m.omegaMultiplier;
      const acc = omega * omega * (target - L.zoom) - 2 * m.damping * omega * L.vel;
      L.vel += acc * dt;
      L.zoom += L.vel * dt;
      el.style.transform = `scale(${0.55 + (L.zoom - 1) * 0.35})`;
    }
    L.last = now;
  });
  return (
    <div ref={ref} className="cc-livepad cc-livepad--elevated" style={{ height: 96 }} aria-hidden>
      <span ref={card} className="cc-livepad__abs cc-fxpad__card" />
    </div>
  );
}

// ── Property preview pad ────────────────────────────────────────────────

export type PropertyPadMode =
  | { kind: "parallax"; strength: number }
  | { kind: "motionBlur"; on: boolean; strength: number }
  | { kind: "frameStyle"; cornerRadius: number; shadowRadius: number; shadowOpacity: number }
  | { kind: "highlightMask"; opacity: number };

export function PropertyPreviewPad({ mode }: { mode: PropertyPadMode }) {
  const ref = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLSpanElement>(null);
  const trails = useRef<(HTMLSpanElement | null)[]>([]);
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const start = useRef(typeof performance !== "undefined" ? performance.now() / 1000 : 0);

  useFrameLoop(ref, (now) => {
    const box = ref.current;
    const c = card.current;
    if (!box || !c) return;
    const w = box.offsetWidth;
    const h = box.offsetHeight;
    const cx = w / 2;
    const cy = h / 2;
    const m = modeRef.current;
    const elapsed = now - start.current;
    const place = (el: HTMLElement, x: number, y: number, bw: number, bh: number) => {
      el.style.left = `${x - bw / 2 - 1}px`;
      el.style.top = `${y - bh / 2 - 1}px`;
      el.style.width = `${bw}px`;
      el.style.height = `${bh}px`;
    };
    for (const t of trails.current) if (t) t.style.display = "none";
    c.style.boxShadow = "none";
    c.style.transform = "none";
    if (m.kind === "parallax") {
      const p = (elapsed % 2.6) / 2.6;
      const zoom = 1 + 0.18 * Math.sin(p * Math.PI);
      const drift = (zoom - 1) * m.strength * 60;
      trails.current.slice(0, 3).forEach((t, i) => {
        if (!t) return;
        t.style.display = "block";
        t.style.background = "rgb(255 255 255 / 0.3)";
        t.style.borderRadius = "2px";
        t.style.transform = "none";
        t.style.left = `${w * (0.2 + i * 0.3) - drift * 0.6 - 2 - 1}px`;
        t.style.top = `${h - 16 - 1}px`;
        t.style.width = "4px";
        t.style.height = "4px";
      });
      place(c, cx, cy, w * 0.4, h * 0.46);
      c.style.borderRadius = "3px";
      c.style.transform = `scale(${zoom})`;
    } else if (m.kind === "motionBlur") {
      const p = (elapsed % 2.6) / 2.6;
      const phase = p * 2 * Math.PI;
      const x = w * 0.14 + w * 0.72 * (0.5 - 0.5 * Math.cos(phase));
      const speed = Math.abs(Math.sin(phase));
      const dir = Math.sin(phase) >= 0 ? 1 : -1;
      const shape = 12;
      const smear = m.on ? speed * Math.max(0, Math.min(1, m.strength)) * 34 : 0;
      if (m.on && smear > 1) {
        trails.current.forEach((t, i) => {
          if (!t) return;
          const f = (i + 1) / trails.current.length;
          t.style.display = "block";
          t.style.background = `rgb(255 255 255 / ${0.45 * speed * (1 - f) * Math.min(1, m.strength + 0.3)})`;
          t.style.borderRadius = `${shape / 2}px`;
          t.style.transform = "none";
          place(t, x - dir * smear * f, cy, shape, shape);
        });
      }
      const stretch = 1 + (m.on ? speed * 0.5 * Math.min(1, m.strength) : 0);
      place(c, x, cy, shape, shape);
      c.style.borderRadius = `${shape / 2}px`;
      c.style.transform = `scaleX(${stretch})`;
    } else if (m.kind === "frameStyle") {
      const cw = w * 0.5;
      const ch = h * 0.6;
      place(c, cx, cy, cw, ch);
      const scale = Math.min(cw, ch) / 80;
      c.style.borderRadius = `${m.cornerRadius * scale * 0.6}px`;
      c.style.boxShadow = `0 0 ${m.shadowRadius * scale * 0.3 * 2}px rgb(0 0 0 / ${m.shadowOpacity})`;
    } else {
      place(c, cx, cy, w * 0.32, h * 0.4);
      c.style.borderRadius = "4px";
    }
  });

  const dim = mode.kind === "highlightMask" ? mode.opacity : null;
  return (
    <div ref={ref} className="cc-livepad cc-livepad--elevated" style={{ height: 96 }} aria-hidden>
      {dim != null && <span className="cc-livepad__abs" style={{ inset: -1, background: `rgb(0 0 0 / ${dim})` }} />}
      {[0, 1, 2, 3, 4].map((i) => (
        <span
          key={i}
          ref={(el) => {
            trails.current[i] = el;
          }}
          className="cc-livepad__abs"
          style={{ display: "none" }}
        />
      ))}
      <span ref={card} className="cc-livepad__abs cc-proppad__card" />
    </div>
  );
}

// ── Subtitle position pad ───────────────────────────────────────────────

export function SubtitlePositionPad({
  s,
  onPlace,
  onSnap,
}: {
  s: ProjectSettings;
  onPlace: (x: number, y: number) => void;
  onSnap: (anchor: "Top" | "Center" | "Bottom") => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const size = useSize(ref);
  const inset = 8;
  const pill = { w: 30, h: 16 };
  const custom = s.subtitleCustomX != null && s.subtitleCustomY != null;
  const f = custom
    ? { x: Math.min(1, Math.max(0, s.subtitleCustomX!)), y: Math.min(1, Math.max(0, s.subtitleCustomY!)) }
    : { x: 0.5, y: s.subtitlePosition === "Top" ? 0 : s.subtitlePosition === "Center" ? 0.5 : 1 };
  const latest = useRef({ ...f, custom });
  latest.current = { ...f, custom };
  const drag = useDrag(
    (x, y, el) => {
      const uw = Math.max(1, el.offsetWidth - 2 * inset - pill.w);
      const uh = Math.max(1, el.offsetHeight - 2 * inset - pill.h);
      const nx = Math.min(1, Math.max(0, (x + 1 - inset - pill.w / 2) / uw));
      const ny = Math.min(1, Math.max(0, (y + 1 - inset - pill.h / 2) / uh));
      latest.current = { x: nx, y: ny, custom: true };
      onPlace(nx, ny);
    },
    () => {
      const { x, y, custom: c } = latest.current;
      if (!c || Math.abs(x - 0.5) >= 0.08) return;
      for (const [anchor, fy] of [
        ["Top", 0],
        ["Center", 0.5],
        ["Bottom", 1],
      ] as const) {
        if (Math.abs(y - fy) < 0.08) {
          onSnap(anchor);
          return;
        }
      }
    },
  );
  const uw = Math.max(1, size.w - 2 * inset - pill.w);
  const uh = Math.max(1, size.h - 2 * inset - pill.h);
  return (
    <div ref={ref} className="cc-livepad cc-livepad--ink" style={{ height: 96 }} {...drag}>
      {size.w > 0 && (
        <>
          <span
            className="cc-livepad__abs"
            style={{
              left: (size.w - size.w * 0.42) / 2 - 1,
              top: (size.h - size.h * 0.42) / 2 - 6 - 1,
              width: size.w * 0.42,
              height: size.h * 0.42,
              borderRadius: 3,
              background: "rgb(255 255 255 / 0.08)",
            }}
          />
          <span className="cc-livepad__abs cc-subpad__pill" style={{ left: inset + uw * f.x - 1, top: inset + uh * f.y - 1 }}>
            Aa
          </span>
        </>
      )}
    </div>
  );
}

// ── Watermark pad ───────────────────────────────────────────────────────

export function WatermarkPad({
  s,
  logoUrl,
  logoAspect,
  onPlace,
  onRelease,
}: {
  s: ProjectSettings;
  logoUrl?: string;
  logoAspect?: number;
  onPlace: (x: number, y: number) => void;
  onRelease: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const size = useSize(ref);
  const inset = 8;
  const t = (Math.min(400, Math.max(40, s.watermarkSize)) - 40) / 360;
  const mw = 12 + t * 44;
  const aspect = logoUrl && logoAspect ? logoAspect : 1.5;
  const mh = mw / Math.max(0.35, Math.min(4, aspect));
  const drag = useDrag((x, y, el) => {
    const uw = Math.max(1, el.offsetWidth - 2 * inset - mw);
    const uh = Math.max(1, el.offsetHeight - 2 * inset - mh);
    onPlace(Math.min(1, Math.max(0, (x + 1 - inset - mw / 2) / uw)), Math.min(1, Math.max(0, (y + 1 - inset - mh / 2) / uh)));
  }, onRelease);
  const uw = Math.max(1, size.w - 2 * inset - mw);
  const uh = Math.max(1, size.h - 2 * inset - mh);
  const fx = Math.min(1, Math.max(0, s.watermarkX));
  const fy = Math.min(1, Math.max(0, s.watermarkY));
  const alpha = Math.max(0.35, s.watermarkOpacity);
  const frame: CSSProperties = { left: inset + uw * fx - 1, top: inset + uh * fy - 1, width: mw, height: mh, opacity: alpha };
  return (
    <div ref={ref} className="cc-livepad cc-livepad--ink" style={{ height: 96 }} {...drag}>
      {size.w > 0 &&
        (logoUrl ? (
          <img className="cc-livepad__abs" src={logoUrl} alt="" draggable={false} style={{ ...frame, objectFit: "contain" }} />
        ) : (
          <span className="cc-livepad__abs cc-wmpad__seal" style={frame}>
            <SFIcon name="seal.fill" size={12} weight="regular" />
          </span>
        ))}
    </div>
  );
}

// ── Subtitle preset card ────────────────────────────────────────────────

const WEIGHT: Record<string, number> = { Regular: 400, Medium: 500, Semibold: 600, Bold: 700, Heavy: 800 };

export function SubtitlePresetCard({ preset, active, onClick }: { preset: SubtitlePreset; active: boolean; onClick: () => void }) {
  const tint = toRGBA(preset.karaoke ? (preset.highlight ?? { red: 1, green: 0.839, blue: 0, opacity: 1 }) : preset.color);
  const base = toRGBA(preset.color);
  const shadow =
    preset.style === "Glow" ? `0 0 5px ${css(base, 0.9)}` : preset.style === "Outline" ? "0 0 1.5px #000" : "none";
  // `.background` style: the attributed backgroundColor (preset fill at .75)
  // hugs the glyph run.
  const bg = preset.style === "Background" ? css(toRGBA(preset.background ?? { red: 0, green: 0, blue: 0, opacity: 1 }), 0.75) : undefined;
  return (
    <button type="button" className="cc-subcard" data-active={active || undefined} onClick={onClick} aria-pressed={active}>
      <span className="cc-subcard__sample">
        <span style={{ color: css(tint), fontWeight: WEIGHT[preset.weight] ?? 400, textShadow: shadow, background: bg, lineHeight: "18px" }}>
          {preset.uppercase ? "AA" : "Aa"}
        </span>
      </span>
      <span className="cc-subcard__name">{preset.name}</span>
    </button>
  );
}
