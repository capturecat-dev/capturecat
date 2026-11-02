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

/**
 * A compact dark pill floating over the page, centred. It reads the same on
 * the light home and on the dark pages (explicit colours, never the theme
 * tokens, which the light home re-points). Scrolling tightens it and deepens
 * its shadow. On small screens the links collapse into a dark sheet below.
 */
export default function Navbar() {
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
          className={`relative mx-auto flex w-full max-w-[760px] items-center justify-between gap-2 rounded-full bg-[#111116]/85 pl-3.5 pr-1.5 text-white ring-1 ring-white/10 backdrop-blur-xl transition-all duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${
            scrolled || open
              ? "h-12 shadow-[0_14px_40px_-14px_rgba(0,0,0,0.6)]"
              : "h-[52px] shadow-[0_10px_30px_-16px_rgba(0,0,0,0.45)]"
          }`}
        >
          <span
            aria-hidden
            className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/25 to-transparent"
          />

          <Link
            to="/"
            onClick={() => setOpen(false)}
            className="flex shrink-0 items-center gap-2 text-[14.5px] font-semibold tracking-[-0.01em] text-white transition-opacity hover:opacity-80"
          >
            <CaptureCatMark className="h-6 w-6" />
            CaptureCat
          </Link>

          <nav className="flex items-center gap-0.5 text-[13.5px]">
            {NAV.map((item) => (
              <Link
                key={item.to}
                to={item.to}
                className="hidden rounded-full px-3 py-1.5 text-white/62 transition-colors hover:bg-white/[0.06] hover:text-white md:inline-block"
                activeProps={{ className: "!text-white" }}
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
              className="hidden h-8 w-8 items-center justify-center rounded-full text-white/62 transition-colors hover:bg-white/[0.06] hover:text-white sm:inline-flex"
            >
              <GitHubIcon className="h-[16px] w-[16px]" />
            </a>
            <Link
              to="/login"
              className="hidden rounded-full px-3 py-1.5 text-white/62 transition-colors hover:bg-white/[0.06] hover:text-white sm:inline-block"
            >
              Log in
            </Link>
            <Link
              to="/download"
              className="ml-1 inline-flex h-9 items-center justify-center rounded-full bg-white px-4 font-medium text-[#0b0b0f] transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98]"
            >
              Download
            </Link>
            <button
              type="button"
              aria-label={open ? "Close menu" : "Open menu"}
              aria-expanded={open}
              onClick={() => setOpen((v) => !v)}
              className="ml-0.5 inline-flex h-9 w-9 items-center justify-center rounded-full text-white/70 transition-colors hover:text-white md:hidden"
            >
              {open ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
            </button>
          </nav>
        </div>

        {open && (
          <div className="relative mx-auto mt-2 w-full max-w-[760px] overflow-hidden rounded-3xl bg-[#111116]/92 p-2 text-white shadow-[0_20px_60px_-20px_rgba(0,0,0,0.7)] ring-1 ring-white/10 backdrop-blur-xl md:hidden">
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener"
              onClick={() => setOpen(false)}
              className="flex items-center gap-2.5 rounded-2xl px-4 py-3 text-[15px] text-white/70 transition-colors hover:bg-white/[0.06] hover:text-white"
            >
              <GitHubIcon className="h-4 w-4" />
              Source on GitHub
            </a>
            {[...NAV, { to: "/login", label: "Log in" } as const].map((item) => (
              <Link
                key={item.to}
                to={item.to}
                onClick={() => setOpen(false)}
                className="block rounded-2xl px-4 py-3 text-[15px] text-white/70 transition-colors hover:bg-white/[0.06] hover:text-white"
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
