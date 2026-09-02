import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { Menu, X } from "lucide-react";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { GITHUB_URL, GitHubIcon } from "./primitives";

const NAV = [
  { to: "/features", label: "Features" },
  { to: "/pricing", label: "Pricing" },
  { to: "/compare", label: "Compare" },
  { to: "/agents", label: "Agents" },
] as const;

/**
 * Floating glass pill that condenses on scroll. At the top it spans the
 * content width; once you scroll it narrows, shortens, and gains a stronger
 * backdrop and shadow so it reads as a dock floating over the page. On small
 * screens the links collapse into a glass sheet under the pill.
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
      <div
        className={`mx-auto px-6 transition-all duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${
          scrolled ? "max-w-5xl pt-3" : "max-w-6xl pt-4"
        }`}
      >
        <div
          className={`relative flex items-center justify-between rounded-full border px-3 pl-4 backdrop-blur-2xl transition-all duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${
            scrolled || open
              ? "h-12 border-white/15 bg-white/[0.07] shadow-[0_10px_36px_-10px_rgba(0,0,0,0.55)]"
              : "h-14 border-white/10 bg-white/[0.05]"
          }`}
        >
          <span
            aria-hidden
            className="absolute inset-x-12 top-0 h-px bg-gradient-to-r from-transparent via-white/35 to-transparent"
          />

          <Link
            to="/"
            onClick={() => setOpen(false)}
            className="flex items-center gap-2.5 text-[15px] font-semibold tracking-[-0.01em] transition-opacity hover:opacity-80"
          >
            <CaptureCatMark
              className={`transition-all duration-500 ${scrolled ? "h-6 w-6" : "h-7 w-7"}`}
            />
            CaptureCat
          </Link>

          <nav className="flex items-center gap-1 text-sm">
            {NAV.map((item) => (
              <Link
                key={item.to}
                to={item.to}
                className="hidden rounded-full px-3.5 py-2 text-muted-foreground transition-colors hover:text-foreground md:inline-block"
                activeProps={{ className: "text-foreground" }}
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
              className="hidden h-9 w-9 items-center justify-center rounded-full text-muted-foreground transition-colors hover:text-foreground sm:inline-flex"
            >
              <GitHubIcon className="h-[17px] w-[17px]" />
            </a>
            <Link
              to="/login"
              className="hidden rounded-full px-3.5 py-2 text-muted-foreground transition-colors hover:text-foreground sm:inline-block"
            >
              Log in
            </Link>
            <Link
              to="/download"
              className="ml-1 inline-flex h-9 items-center justify-center rounded-full bg-white px-4 font-medium text-black transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98]"
            >
              Download
            </Link>
            <button
              type="button"
              aria-label={open ? "Close menu" : "Open menu"}
              aria-expanded={open}
              onClick={() => setOpen((v) => !v)}
              className="ml-1 inline-flex h-9 w-9 items-center justify-center rounded-full text-muted-foreground transition-colors hover:text-foreground md:hidden"
            >
              {open ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
            </button>
          </nav>
        </div>

        {open && (
          <div className="relative mt-2 overflow-hidden rounded-3xl border border-white/12 bg-white/[0.07] p-2 shadow-[0_20px_60px_-20px_rgba(0,0,0,0.7)] backdrop-blur-2xl md:hidden">
            <span
              aria-hidden
              className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/35 to-transparent"
            />
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener"
              onClick={() => setOpen(false)}
              className="flex items-center gap-2.5 rounded-2xl px-4 py-3 text-[15px] text-muted-foreground transition-colors hover:bg-white/[0.06] hover:text-foreground"
            >
              <GitHubIcon className="h-4 w-4" />
              Source on GitHub
            </a>
            {[...NAV, { to: "/login", label: "Log in" } as const].map((item) => (
              <Link
                key={item.to}
                to={item.to}
                onClick={() => setOpen(false)}
                className="block rounded-2xl px-4 py-3 text-[15px] text-muted-foreground transition-colors hover:bg-white/[0.06] hover:text-foreground"
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
