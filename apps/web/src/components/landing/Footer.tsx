import { Link } from "@tanstack/react-router";
import CaptureCatMark from "@/components/brand/CaptureCatMark";

/**
 * Full-bleed footer, pinned to the bottom on short pages.
 *
 * `mt-auto` only pins anything if the ancestor is a flex column that fills the
 * viewport height — see the wrapper in app/layout.tsx. On its own it is inert,
 * and a short page leaves the footer floating mid-screen.
 */
export default function Footer() {
  return (
    <footer className="relative mt-auto border-t border-white/10">
      <span
        aria-hidden
        className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-white/20 to-transparent"
      />

      <div className="mx-auto max-w-6xl px-6 py-12">
        <div className="flex flex-col gap-10 md:flex-row md:items-start md:justify-between">
          <div className="max-w-sm">
            <div className="flex items-center gap-2.5 text-lg font-semibold tracking-[-0.01em]">
              <CaptureCatMark className="h-8 w-8" />
              CaptureCat
            </div>
            <p className="mt-4 text-sm leading-relaxed text-muted-foreground">
              A screen recorder for people who care what the result looks like.
              Built natively for macOS.
            </p>
          </div>

          <div className="flex flex-wrap gap-x-14 gap-y-8 text-sm">
            <div className="flex flex-col gap-3">
              <span className="font-medium text-foreground">Product</span>
              <Link to="/" hash="features" className="text-muted-foreground transition-colors hover:text-foreground">
                Features
              </Link>
              <Link to="/pricing" className="text-muted-foreground transition-colors hover:text-foreground">
                Pricing
              </Link>
              <Link to="/download" className="text-muted-foreground transition-colors hover:text-foreground">
                Download
              </Link>
              <Link to="/agents" className="text-muted-foreground transition-colors hover:text-foreground">
                Agents &amp; MCP
              </Link>
            </div>
            <div className="flex flex-col gap-3">
              <span className="font-medium text-foreground">Account</span>
              <Link to="/login" className="text-muted-foreground transition-colors hover:text-foreground">
                Sign in
              </Link>
              <Link to="/app" className="text-muted-foreground transition-colors hover:text-foreground">
                Your videos
              </Link>
              <Link to="/app/billing" className="text-muted-foreground transition-colors hover:text-foreground">
                Billing
              </Link>
            </div>
            <div className="flex flex-col gap-3">
              <span className="font-medium text-foreground">Support</span>
              <a
                href="mailto:contact@capturecat.so"
                className="text-muted-foreground transition-colors hover:text-foreground"
              >
                Contact
              </a>
              <Link to="/pricing" className="text-muted-foreground transition-colors hover:text-foreground">
                FAQ
              </Link>
            </div>
            <div className="flex flex-col gap-3">
              <span className="font-medium text-foreground">Legal</span>
              <Link to="/privacy" className="text-muted-foreground transition-colors hover:text-foreground">
                Privacy
              </Link>
              <Link to="/terms" className="text-muted-foreground transition-colors hover:text-foreground">
                Terms
              </Link>
            </div>
          </div>
        </div>

        <div className="mt-10 border-t border-white/8 pt-6 text-xs text-muted-foreground">
          © {new Date().getFullYear()} CaptureCat
        </div>
      </div>
    </footer>
  );
}
