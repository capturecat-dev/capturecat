import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { Menu, X } from "lucide-react";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { GITHUB_URL, GitHubIcon } from "./primitives";

const NAV = [
  { to: "/features", label: "Features" },
  { to: "/pricing", label: "Pricing" },
  { to: "/docs", label: "Docs" },
  { to: "/compare", label: "Compare" },
  { to: "/agents", label: "Agents" },
] as const;

/** Explicit colours per tone, never the theme tokens (the light pages re-point them). */
const TONES = {
  // Marketing pages: frosted white glass with ink type.
  light: {
    pill: "bg-white/75 text-[#0b0b0f] ring-1 ring-black/[0.07] backdrop-blur-xl backdrop-saturate-150",
    pillShadow: "shadow-[0_10px_30px_-16px_rgb(30_20_90/0.35)]",
    pillShadowUp: "shadow-[0_14px_40px_-16px_rgb(30_20_90/0.4)]",
    hairline: "via-white",
    brand: "text-[#0b0b0f]",
    link: "text-[#3a3a44] hover:bg-black/[0.045] hover:text-[#0b0b0f]",
    active: "!text-[#0b0b0f] font-medium",
    cta: "bg-[#0b0b0f] text-white shadow-[inset_0_1px_0_rgb(255_255_255/0.14)]",
    sheet: "bg-white/95 text-[#0b0b0f] ring-1 ring-black/[0.07] shadow-[0_20px_60px_-24px_rgb(30_20_90/0.4)]",
    sheetLink: "text-[#3a3a44] hover:bg-black/[0.045] hover:text-[#0b0b0f]",
    toggle: "text-[#3a3a44] hover:text-[#0b0b0f]",
  },
  // Docs keep their dark surfaces.
  dark: {
    pill: "bg-[#111116]/85 text-white ring-1 ring-white/10 backdrop-blur-xl",
    pillShadow: "shadow-[0_10px_30px_-16px_rgba(0,0,0,0.45)]",
    pillShadowUp: "shadow-[0_14px_40px_-14px_rgba(0,0,0,0.6)]",
    hairline: "via-white/25",
    brand: "text-white",
    link: "text-white/62 hover:bg-white/[0.06] hover:text-white",
    active: "!text-white",
    cta: "bg-white text-[#0b0b0f]",
    sheet: "bg-[#111116]/92 text-white ring-1 ring-white/10 shadow-[0_20px_60px_-20px_rgba(0,0,0,0.7)]",
    sheetLink: "text-white/70 hover:bg-white/[0.06] hover:text-white",
    toggle: "text-white/70 hover:text-white",
  },
} as const;

/**
 * A compact pill floating over the page, centred: frosted white on the light
 * marketing pages, dark on the docs. Scrolling tightens it and deepens its
 * shadow. On small screens the links collapse into a sheet below.
 */
export default function Navbar({ tone = "dark" }: { tone?: keyof typeof TONES }) {
  const t = TONES[tone];
  const [scrolled, setScrolled] = useState(false);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  return (
    <header className="sticky top-0 z-50 w-full">
      <div className={`mx-auto px-4 transition-[padding] duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${scrolled ? "pt-3" : "pt-4"}`}>
        <div
          className={`relative mx-auto flex w-full max-w-[760px] items-center justify-between gap-2 rounded-full pl-3.5 pr-1.5 transition-all duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${t.pill} ${
            scrolled || open ? `h-12 ${t.pillShadowUp}` : `h-[52px] ${t.pillShadow}`
          }`}
        >
          <span
            aria-hidden
            className={`absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent ${t.hairline} to-transparent`}
          />

          <Link
            to="/"
            onClick={() => setOpen(false)}
            className={`flex shrink-0 items-center gap-2 text-[14.5px] font-semibold tracking-[-0.01em] transition-opacity hover:opacity-80 ${t.brand}`}
          >
            <CaptureCatMark className="h-6 w-6" />
            CaptureCat
          </Link>

          <nav className="flex items-center gap-0.5 text-[13.5px]">
            {NAV.map((item) => (
              <Link
                key={item.to}
                to={item.to}
                className={`hidden rounded-full px-3 py-1.5 transition-colors md:inline-block ${t.link}`}
                activeProps={{ className: t.active }}
              >
                {item.label}
              </Link>
            ))}
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener"
              aria-label="CaptureCat on GitHub"
              title="Source on GitHub"
              className={`hidden h-8 w-8 items-center justify-center rounded-full transition-colors sm:inline-flex ${t.link}`}
            >
              <GitHubIcon className="h-[16px] w-[16px]" />
            </a>
            <Link
              to="/login"
              className={`hidden rounded-full px-3 py-1.5 transition-colors sm:inline-block ${t.link}`}
            >
              Log in
            </Link>
            <Link
              to="/download"
              className={`ml-1 inline-flex h-9 items-center justify-center rounded-full px-4 font-medium transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98] ${t.cta}`}
            >
              Download
            </Link>
            <button
              type="button"
              aria-label={open ? "Close menu" : "Open menu"}
              aria-expanded={open}
              onClick={() => setOpen((v) => !v)}
              className={`ml-0.5 inline-flex h-9 w-9 items-center justify-center rounded-full transition-colors md:hidden ${t.toggle}`}
            >
              {open ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
            </button>
          </nav>
        </div>

        {open && (
          <div className={`relative mx-auto mt-2 w-full max-w-[760px] overflow-hidden rounded-3xl p-2 backdrop-blur-xl md:hidden ${t.sheet}`}>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener"
              onClick={() => setOpen(false)}
              className={`flex items-center gap-2.5 rounded-2xl px-4 py-3 text-[15px] transition-colors ${t.sheetLink}`}
            >
              <GitHubIcon className="h-4 w-4" />
              Source on GitHub
            </a>
            {[...NAV, { to: "/login", label: "Log in" } as const].map((item) => (
              <Link
                key={item.to}
                to={item.to}
                onClick={() => setOpen(false)}
                className={`block rounded-2xl px-4 py-3 text-[15px] transition-colors ${t.sheetLink}`}
              >
                {item.label}
              </Link>
            ))}
          </div>
        )}
      </div>
    </header>
  );
}
