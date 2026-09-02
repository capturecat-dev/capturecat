import { createFileRoute } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";
import { markdownAlternateLinks } from "@/lib/site-content";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { DownloadButtons } from "@/components/marketing/download-buttons";
import { MediaPlaceholder } from "@/components/marketing/MediaPlaceholder";
import {
  Ambient,
  Container,
  Eyebrow,
  GlassCard,
  SectionTitle,
} from "@/components/marketing/primitives";

async function getLatestRelease() {
  try {
    const res = await fetch(`${API_URL}/api/releases/latest`, {
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    return res.json() as Promise<{
      version: string;
      date: string;
      minOS: string;
      notes: string;
      downloads: { arm64: string; x86_64: string };
    }>;
  } catch {
    return null;
  }
}

export const Route = createFileRoute("/download")({
  loader: async () => ({ release: await getLatestRelease() }),
  head: () => ({
    meta: [
      { title: "Download CaptureCat for macOS | CaptureCat" },
      {
        name: "description",
        content:
          "Download CaptureCat, the free native screen recorder for macOS 14 and later. Builds for Apple Silicon and Intel. No account needed to record.",
      },
    ],
    links: markdownAlternateLinks("/download"),
  }),
  component: DownloadPage,
});

const STEPS = [
  {
    title: "Open the disk image and drag the app to Applications",
    body: "The download is a signed and notarised .dmg. macOS will verify it on first open, which takes a second or two.",
  },
  {
    title: "Allow screen recording",
    body: "macOS asks once. CaptureCat needs Screen Recording to capture, and Microphone and Camera only if you turn those sources on. Keystroke capture, which powers the key sounds and the shortcut pill, asks for Input Monitoring the first time you use it.",
  },
  {
    title: "Record from the menu bar",
    body: "CaptureCat lives in the menu bar. Click the icon or press the global shortcut, pick a source, and press record. Stop the same way. The editor opens with the auto edit already applied.",
  },
  {
    title: "Export, or sign in to share",
    body: "Export is free at full quality. If you want a link instead of a file, sign in with Google or Apple from inside the app and upload. That is the only part that needs an account.",
  },
];

function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}

function DownloadPage() {
  const { release } = Route.useLoaderData();

  return (
    <main className="flex min-h-screen flex-col bg-background">
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <Ambient variant="hero" />
        <Container className="flex flex-col items-center pb-16 pt-16 text-center md:pt-24">
          <Eyebrow>
            {release ? `Version ${release.version}, released ${formatDate(release.date)}` : "macOS app"}
          </Eyebrow>
          <h1 className="mt-6 max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            Download CaptureCat for Mac
          </h1>
          <p className="mx-auto mt-6 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground">
            Free to record, edit, and export. No account needed until you want
            a share link. Pick the build for your Mac, or let the page guess.
          </p>

          {release ? (
            <>
              <DownloadButtons release={release} />
              <p className="mt-4 text-sm text-muted-foreground">
                Requires macOS {release.minOS || "14 Sonoma"} or later. Not sure which Mac you have? Open the Apple menu, then About This
                Mac. Apple Silicon says Apple M1 or later under Chip.
              </p>
            </>
          ) : (
            <p className="mt-8 text-lg text-muted-foreground">
              The download is not available right now. Try again in a few minutes.
            </p>
          )}
        </Container>
      </section>

      <section className="relative isolate py-16">
        <Container>
          <div className="grid grid-cols-1 items-start gap-10 lg:grid-cols-12 lg:gap-14">
            <div className="lg:col-span-5">
              <SectionTitle muted="About two minutes, most of it macOS asking permission.">
                After the download
              </SectionTitle>
              <ol className="mt-8 space-y-6">
                {STEPS.map((step, i) => (
                  <li key={step.title} className="flex gap-4">
                    <span className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-full border border-white/12 bg-white/[0.07] text-sm font-medium shadow-[inset_0_1px_0_rgba(255,255,255,0.18)]">
                      {i + 1}
                    </span>
                    <div>
                      <h3 className="text-[16px] font-medium tracking-[-0.01em] text-foreground">
                        {step.title}
                      </h3>
                      <p className="mt-1.5 text-[14.5px] leading-relaxed text-muted-foreground">
                        {step.body}
                      </p>
                    </div>
                  </li>
                ))}
              </ol>
            </div>
            <div className="flex flex-col gap-6 lg:col-span-7">
              <MediaPlaceholder id="download-first-launch" />
              <MediaPlaceholder id="download-menu-bar" />
            </div>
          </div>
        </Container>
      </section>

      <section className="relative isolate py-16 pb-28">
        <Container>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <GlassCard padding="p-7">
              <h3 className="text-[17px] font-medium tracking-[-0.01em]">Updates</h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                The app checks for updates itself and installs them in the
                background. You can also check from the menu bar menu.
              </p>
            </GlassCard>
            <GlassCard padding="p-7">
              <h3 className="text-[17px] font-medium tracking-[-0.01em]">Uninstalling</h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                Drag the app to the Bin. Your recordings are ordinary project
                folders in Application Support and stay where they are.
              </p>
            </GlassCard>
            <GlassCard padding="p-7">
              <h3 className="text-[17px] font-medium tracking-[-0.01em]">Release notes</h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                {release?.notes
                  ? release.notes
                  : "Each release ships with notes inside the update prompt, so you can see what changed before installing."}
              </p>
            </GlassCard>
          </div>
        </Container>
      </section>

      <Footer />
    </main>
  );
}
