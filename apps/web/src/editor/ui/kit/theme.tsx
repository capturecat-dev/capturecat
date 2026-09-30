/**
 * ThemeRoot — the `.cc-theme` scope every editor surface lives in (the web
 * twin of CCTheme.current + CCThemeObservation).
 *
 *  • mode: "dark" | "light" | "system" (Mac default: system), persisted per
 *    viewer in localStorage — a convenience, never required.
 *  • Springs are serialised into inline CSS variables (--cc-spring-*), so CSS
 *    transitions spring with zero JS per frame.
 *  • A portal host INSIDE the scope, so menus/popovers inherit the tokens.
 *  • Canvas surfaces (timeline) read resolved token values via
 *    `readCanvasTokens` and re-read on `themeKey` changes.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";

import { setMotionPace, springCssVars, type Pace } from "./motion";

export type ThemeMode = "dark" | "light" | "system";
export type ResolvedTheme = "dark" | "light";

const STORAGE_KEY = "cc.editor.themeMode";

interface ThemeContextValue {
  mode: ThemeMode;
  resolved: ResolvedTheme;
  setMode: (mode: ThemeMode) => void;
  /** Bumps on every resolved-theme change — canvas surfaces re-read tokens. */
  themeKey: number;
  /** Portal host inside the themed scope. */
  portal: HTMLElement | null;
  root: HTMLElement | null;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function useCCTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error("useCCTheme must be used inside <ThemeRoot>");
  return ctx;
}

export function ThemeRoot({
  children,
  initialMode = "system",
  persist = true,
  pace = "standard",
  className,
  style,
}: {
  children: ReactNode;
  initialMode?: ThemeMode;
  /** false for harnesses/labs that pin a mode (CCTheme.setMode(persist: false)). */
  persist?: boolean;
  pace?: Pace;
  className?: string;
  style?: CSSProperties;
}) {
  const [mode, setModeState] = useState<ThemeMode>(initialMode);
  const [systemDark, setSystemDark] = useState(true);
  const [themeKey, setThemeKey] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const [portal, setPortal] = useState<HTMLElement | null>(null);
  const [root, setRoot] = useState<HTMLElement | null>(null);

  useEffect(() => {
    setMotionPace(pace);
  }, [pace]);

  // Restore the persisted choice after hydration (SSR renders the default).
  useEffect(() => {
    if (!persist) return;
    try {
      const stored = window.localStorage.getItem(STORAGE_KEY) as ThemeMode | null;
      if (stored === "dark" || stored === "light" || stored === "system") setModeState(stored);
    } catch {
      /* storage blocked — default stands */
    }
  }, [persist]);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const sync = () => setSystemDark(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  const resolved: ResolvedTheme = mode === "system" ? (systemDark ? "dark" : "light") : mode;

  useEffect(() => {
    setThemeKey((k) => k + 1);
  }, [resolved]);

  const setMode = useCallback(
    (next: ThemeMode) => {
      setModeState(next);
      if (!persist) return;
      try {
        window.localStorage.setItem(STORAGE_KEY, next);
      } catch {
        /* ignore */
      }
    },
    [persist],
  );

  const springVars = useMemo(() => springCssVars(pace) as CSSProperties, [pace]);

  useEffect(() => {
    setRoot(rootRef.current);
  }, []);

  const value = useMemo(
    () => ({ mode, resolved, setMode, themeKey, portal, root }),
    [mode, resolved, setMode, themeKey, portal, root],
  );

  return (
    <ThemeContext.Provider value={value}>
      <div
        ref={rootRef}
        className={`cc-theme${className ? ` ${className}` : ""}`}
        data-cc-theme={mode}
        data-cc-resolved={resolved}
        data-cc-pace={pace}
        style={{ ...springVars, ...style }}
      >
        {children}
        <div className="cc-portal" ref={setPortal} />
      </div>
    </ThemeContext.Provider>
  );
}

// ── Canvas token access ─────────────────────────────────────────────────

export interface RGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

/** Parses the colour syntaxes tokens.css uses: #rgb/#rrggbb, rgb()/rgba() in
 *  comma or space/slash form. */
export function parseColor(input: string): RGBA {
  const s = input.trim();
  if (s.startsWith("#")) {
    const hex = s.slice(1);
    const full = hex.length === 3 ? hex.split("").map((c) => c + c).join("") : hex;
    const n = Number.parseInt(full.slice(0, 6), 16);
    const a = full.length === 8 ? Number.parseInt(full.slice(6, 8), 16) / 255 : 1;
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a };
  }
  const m = s.match(/rgba?\(([^)]+)\)/i);
  if (m) {
    const parts = m[1].replace(/\//g, " ").replace(/,/g, " ").split(/\s+/).filter(Boolean);
    const num = (p: string, scale: number) => (p.endsWith("%") ? (Number.parseFloat(p) / 100) * scale : Number.parseFloat(p));
    return {
      r: num(parts[0], 255),
      g: num(parts[1], 255),
      b: num(parts[2], 255),
      a: parts[3] !== undefined ? num(parts[3], 1) : 1,
    };
  }
  return { r: 0, g: 0, b: 0, a: 1 };
}

export const rgbaString = (c: RGBA, alpha = c.a) =>
  `rgba(${Math.round(c.r)}, ${Math.round(c.g)}, ${Math.round(c.b)}, ${+alpha.toFixed(4)})`;

/** NSColor.blended(withFraction:of:) — straight RGB lerp. */
export const blend = (a: RGBA, b: RGBA, fraction: number): RGBA => ({
  r: a.r + (b.r - a.r) * fraction,
  g: a.g + (b.g - a.g) * fraction,
  b: a.b + (b.b - a.b) * fraction,
  a: a.a + (b.a - a.a) * fraction,
});

export interface CanvasTokens {
  dark: boolean;
  background: RGBA;
  card: RGBA;
  elevated: RGBA;
  foreground: RGBA;
  muted: RGBA;
  faint: RGBA;
  border: RGBA;
  ink: RGBA;
  red: RGBA;
  orange: RGBA;
  yellow: RGBA;
  cyan: RGBA;
  laneEffectTop: RGBA;
  laneEffectBottom: RGBA;
  laneBlurTop: RGBA;
  laneBlurBottom: RGBA;
  laneHighlightTop: RGBA;
  laneHighlightBottom: RGBA;
  laneAnnotateTop: RGBA;
  laneAnnotateBottom: RGBA;
  snapGuide: RGBA;
  font: string;
  mono: string;
}

export function readCanvasTokens(el: Element): CanvasTokens {
  const cs = getComputedStyle(el);
  const v = (name: string) => parseColor(cs.getPropertyValue(name));
  const ink = v("--cc-ink");
  return {
    dark: ink.r > 128,
    background: v("--cc-background"),
    card: v("--cc-card"),
    elevated: v("--cc-elevated"),
    foreground: v("--cc-foreground"),
    muted: v("--cc-muted"),
    faint: v("--cc-faint"),
    border: v("--cc-border"),
    ink,
    red: v("--cc-system-red"),
    orange: v("--cc-system-orange"),
    yellow: v("--cc-system-yellow"),
    cyan: v("--cc-system-cyan"),
    laneEffectTop: v("--cc-lane-effect-top"),
    laneEffectBottom: v("--cc-lane-effect-bottom"),
    laneBlurTop: v("--cc-lane-blur-top"),
    laneBlurBottom: v("--cc-lane-blur-bottom"),
    laneHighlightTop: v("--cc-lane-highlight-top"),
    laneHighlightBottom: v("--cc-lane-highlight-bottom"),
    laneAnnotateTop: v("--cc-lane-annotate-top"),
    laneAnnotateBottom: v("--cc-lane-annotate-bottom"),
    snapGuide: v("--cc-snap-guide"),
    font: cs.getPropertyValue("--cc-font").trim() || "system-ui, sans-serif",
    mono: cs.getPropertyValue("--cc-font-mono").trim() || "monospace",
  };
}
