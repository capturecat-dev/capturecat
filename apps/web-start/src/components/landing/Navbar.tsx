import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import CaptureCatMark from "@/components/brand/CaptureCatMark";

/**
 * Floating glass pill that condenses on scroll: at the top it spans the
 * content width; once you scroll it narrows, shortens, and gains a stronger
 * backdrop + shadow so it reads as a floating dock over the page.
 */
export default function Navbar() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className="sticky top-0 z-50 w-full">
      <div
        className={`mx-auto px-6 transition-all duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${
          scrolled ? "max-w-5xl pt-3" : "max-w-6xl pt-4"
        }`}
      >
        <div
          className={`relative flex items-center justify-between rounded-full border px-3 pl-4 backdrop-blur-2xl transition-all duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${
            scrolled
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
            className="flex items-center gap-2.5 text-[15px] font-semibold tracking-[-0.01em] transition-opacity hover:opacity-80"
          >
            <CaptureCatMark
              className={`transition-all duration-500 ${scrolled ? "h-6 w-6" : "h-7 w-7"}`}
            />
            CaptureCat
          </Link>

          <nav className="flex items-center gap-1 text-sm">
            <Link
              to="/" hash="features"
              className="hidden rounded-full px-3.5 py-2 text-muted-foreground transition-colors hover:text-foreground sm:inline-block"
            >
              Features
            </Link>
            <Link
              to="/pricing"
              className="hidden rounded-full px-3.5 py-2 text-muted-foreground transition-colors hover:text-foreground sm:inline-block"
            >
              Pricing
            </Link>
            <Link
              to="/agents"
              className="hidden rounded-full px-3.5 py-2 text-muted-foreground transition-colors hover:text-foreground sm:inline-block"
            >
              Agents
            </Link>
            <Link
              to="/login"
              className="rounded-full px-3.5 py-2 text-muted-foreground transition-colors hover:text-foreground"
            >
              Log in
            </Link>
            <Link
              to="/download"
              className="ml-1 inline-flex h-9 items-center justify-center rounded-full bg-white px-4 font-medium text-black transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98]"
            >
              Download
            </Link>
          </nav>
        </div>
      </div>
    </header>
  );
}
