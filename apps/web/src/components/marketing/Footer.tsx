import { Link } from "@tanstack/react-router";
import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { GITHUB_URL, GitHubIcon } from "./primitives";

const COLUMNS: Array<{
  heading: string;
  links: Array<{ label: string; to?: string; href?: string; hash?: string }>;
}> = [
  {
    heading: "Product",
    links: [
      { label: "Features", to: "/features" },
      { label: "Pricing", to: "/pricing" },
      { label: "Download", to: "/download" },
      { label: "Agents and MCP", to: "/agents" },
    ],
  },
  {
    heading: "Compare",
    links: [
      { label: "All comparisons", to: "/compare" },
      { label: "vs Screen Studio", href: "/compare/capturecat-vs-screen-studio" },
      { label: "vs Loom", href: "/compare/capturecat-vs-loom" },
      { label: "vs Cap", href: "/compare/capturecat-vs-cap" },
    ],
  },
  {
    heading: "Account",
    links: [
      { label: "Sign in", to: "/login" },
      { label: "Your videos", to: "/app" },
      { label: "Billing", to: "/app/billing" },
    ],
  },
  {
    heading: "Open source",
    links: [
      { label: "GitHub", href: GITHUB_URL },
      { label: "Licence (AGPL-3.0)", href: `${GITHUB_URL}/blob/main/LICENSE` },
      { label: "Report a bug", href: `${GITHUB_URL}/issues` },
      { label: "Contact", href: "mailto:contact@capturecat.so" },
      { label: "Privacy", to: "/privacy" },
      { label: "Terms", to: "/terms" },
    ],
  },
];

/**
 * Full-bleed footer, pinned to the bottom on short pages.
 *
 * `mt-auto` only pins anything if the ancestor is a flex column that fills the
 * viewport height, so every page's <main> is `min-h-screen flex flex-col`.
 */
export default function Footer() {
  return (
    <footer className="relative mt-auto border-t border-white/10">
      <span
        aria-hidden
        className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-white/20 to-transparent"
      />

      <div className="mx-auto max-w-6xl px-6 py-14">
        <div className="flex flex-col gap-12 md:flex-row md:items-start md:justify-between">
          <div className="max-w-xs">
            <div className="flex items-center gap-2.5 text-lg font-semibold tracking-[-0.01em]">
              <CaptureCatMark className="h-8 w-8" />
              CaptureCat
            </div>
            <p className="mt-4 text-sm leading-relaxed text-muted-foreground">
              A screen recorder for Mac that does the editing for you. Native
              Swift, no web view, free to record and export. Open source under
              the AGPL, so you can read every line of it.
            </p>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener"
              className="mt-5 inline-flex items-center gap-2 text-sm text-muted-foreground transition-colors hover:text-foreground"
            >
              <GitHubIcon className="h-4 w-4" />
              capturecat-dev/capturecat
            </a>
            <Link
              to="/download"
              className="mt-4 inline-flex h-10 items-center justify-center rounded-full bg-white px-5 text-sm font-medium text-black transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98]"
            >
              Download for Mac
            </Link>
          </div>

          <div className="grid grid-cols-2 gap-x-12 gap-y-10 text-sm sm:grid-cols-4">
            {COLUMNS.map((col) => (
              <div key={col.heading} className="flex flex-col gap-3">
                <span className="font-medium text-foreground">{col.heading}</span>
                {col.links.map((l) =>
                  l.to ? (
                    <Link
                      key={l.label}
                      to={l.to}
                      className="text-muted-foreground transition-colors hover:text-foreground"
                    >
                      {l.label}
                    </Link>
                  ) : (
                    <a
                      key={l.label}
                      href={l.href}
                      className="text-muted-foreground transition-colors hover:text-foreground"
                    >
                      {l.label}
                    </a>
                  )
                )}
              </div>
            ))}
          </div>
        </div>

        <div className="mt-12 flex flex-col gap-2 border-t border-white/8 pt-6 text-xs text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
          <span>© {new Date().getFullYear()} CaptureCat. Made in the UK.</span>
          <span>Requires macOS 14 Sonoma or later. Apple Silicon and Intel.</span>
        </div>
      </div>
    </footer>
  );
}
