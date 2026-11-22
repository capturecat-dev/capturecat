import { createFileRoute } from "@tanstack/react-router";
import { Download, Globe, RefreshCw, ScrollText, Smartphone, Trash2 } from "lucide-react";

import { API_URL } from "@/lib/api-url";
import { pageHead } from "@/lib/site-content";
import { DownloadButtons } from "@/components/marketing/download-buttons";
import { PinnedStory } from "@/components/marketing/home/demo/PinnedStory";
import { DmgScene, ExportScene, MenuBarScene, PermissionScene, SceneSlot } from "@/components/marketing/home/demo/Scenes";
import demosCss from "@/styles/demos.css?url";
import demosPagesCss from "@/styles/demos-pages.css?url";
import airyCss from "@/styles/airy.css?url";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AIR_CELL, AIR_GRID, AirChecks, AirContainer, AirLede, AirPill, AirTitle } from "@/components/marketing/airy/primitives";
import { DevicePhone } from "@/components/marketing/airy/Devices";
import { AppStoreSlot, IosAppScreen } from "@/components/marketing/airy/IosApp";

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
  head: () =>
    pageHead("/download", [
      { rel: "stylesheet", href: demosCss },
      { rel: "stylesheet", href: demosPagesCss },
      { rel: "stylesheet", href: airyCss },
    ]),
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
    body: "CaptureCat lives in the menu bar. Click the icon, pick a source, and press record. Stop from the recording bar or the menu bar. The editor opens with the auto edit already applied.",
  },
  {
    title: "Export, or sign in to share",
    body: "Export is free at full quality for personal use, with no account. If you want a link instead of a file, sign in with Google or Apple from inside the app and upload. If you have Pro for commercial use or recordings over 5 minutes, sign in once with that account.",
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
    <AirPage>
      <AirPageHero
        pill={release ? `Version ${release.version}, released ${formatDate(release.date)}` : "macOS app"}
        icon={<Download className="h-3.5 w-3.5" strokeWidth={2} />}
        title="Download CaptureCat for Mac"
        lede="Free for personal use, with recordings up to 5 minutes. No account needed until you want a share link or Pro. The page picks the right build for your Mac."
      >
        {release ? (
          <>
            <div className="mt-4">
              <DownloadButtons release={release} />
            </div>
            <p className="mt-5 max-w-xl text-[13.5px] leading-relaxed text-[var(--cc-air-faint)]">
              Requires macOS {release.minOS || "14 Sonoma"} or later. Not sure which Mac you have? Open the Apple menu,
              then About This Mac. Apple Silicon says Apple M1 or later under Chip.
            </p>
          </>
        ) : (
          <p className="mt-8 text-lg text-[var(--cc-air-muted)]">
            The download is not available right now. Try again in a few minutes.
          </p>
        )}
        <a
          href="/#everywhere"
          className="group mt-8 inline-flex items-center gap-2 rounded-full bg-white px-3.5 py-1.5 text-[13px] text-[var(--cc-air-ink-2)] shadow-[0_1px_2px_rgb(0_0_0/0.06)] ring-1 ring-black/[0.07] transition-shadow hover:shadow-[0_6px_18px_-8px_rgb(0_0_0/0.2)]"
        >
          <Globe className="h-3.5 w-3.5 text-[var(--cc-air-violet)]" strokeWidth={2} />
          Not on a Mac? CaptureCat also runs in the browser
          <span aria-hidden className="transition-transform group-hover:translate-x-0.5">
            ›
          </span>
        </a>
      </AirPageHero>

      <section className="relative isolate pb-16 pt-8">
        <AirContainer>
          <AirTitle className="max-w-2xl" muted="About two minutes, most of it macOS asking permission.">
            After the download.
          </AirTitle>
          <PinnedStory
            className="ccd-dl mt-6 lg:mt-0"
            stage={
              <>
                <SceneSlot index={0}>
                  <DmgScene />
                </SceneSlot>
                <SceneSlot index={1}>
                  <PermissionScene />
                </SceneSlot>
                <SceneSlot index={2}>
                  <MenuBarScene />
                </SceneSlot>
                <SceneSlot index={3} className="ccd-x-export">
                  <ExportScene />
                </SceneSlot>
              </>
            }
            steps={STEPS.map((step, i) => (
              <div className="flex gap-4">
                <span className="ccd-stepnum inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-white text-sm font-semibold text-[var(--cc-air-ink)] ring-1 ring-black/[0.08]">
                  {i + 1}
                </span>
                <div>
                  <h3 className="text-[22px] font-semibold leading-snug tracking-[-0.025em] text-[var(--cc-air-ink)] md:text-[26px]">
                    {step.title}
                  </h3>
                  <p className="mt-3 max-w-lg text-[15.5px] leading-relaxed text-[var(--cc-air-muted)]">{step.body}</p>
                </div>
              </div>
            ))}
          />
        </AirContainer>
      </section>

      <section id="iphone" className="relative isolate scroll-mt-24 overflow-hidden border-t border-[var(--cc-air-hairline)] py-20 md:py-28">
        <div className="air-wash air-wash--up" aria-hidden />
        <AirContainer>
          <div className="grid items-center gap-12 md:grid-cols-12 md:gap-10">
            <div className="md:col-span-7">
              <AirPill icon={<Smartphone className="h-3.5 w-3.5" strokeWidth={2} />}>iPhone and iPad</AirPill>
              <AirTitle className="mt-5" muted="Edit anywhere.">
                Record on your phone.
              </AirTitle>
              <AirLede className="mt-5 max-w-lg">
                CaptureCat for iPhone and iPad is on its way to the App Store. It records your screen on the go
                and keeps your library with you: sign in with the same account and every project syncs with your
                Mac and the web.
              </AirLede>
              <AirChecks
                items={[
                  "Record the screen from the app or from Control Center",
                  "Your whole library, with share links you can copy",
                  "Continue on your Mac to edit with the full editor",
                ]}
              />
              <AppStoreSlot className="mt-8" />
            </div>
            <div className="flex justify-center md:col-span-5">
              <div className="air-phone-solo w-[min(62vw,260px)]">
                <DevicePhone>
                  <IosAppScreen />
                </DevicePhone>
              </div>
            </div>
          </div>
        </AirContainer>
      </section>

      <section className="border-t border-[var(--cc-air-hairline)] bg-white py-20 md:py-24">
        <AirContainer>
          <div className={`${AIR_GRID} md:grid-cols-3`}>
            {[
              {
                icon: RefreshCw,
                title: "Updates",
                body: "The app checks for updates itself and installs them in the background. You can also check from the menu bar menu.",
              },
              {
                icon: Trash2,
                title: "Uninstalling",
                body: "Drag the app to the Bin. Your recordings are ordinary project folders in Application Support and stay where they are.",
              },
              {
                icon: ScrollText,
                title: "Release notes",
                body:
                  release?.notes ||
                  "Each release ships with notes inside the update prompt, so you can see what changed before installing.",
              },
            ].map((card) => (
              <div key={card.title} className={`${AIR_CELL} p-7 md:p-8`}>
                <card.icon className="h-5 w-5 text-[var(--cc-air-violet)]" strokeWidth={1.75} />
                <h3 className="mt-5 text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{card.title}</h3>
                <p className="mt-1.5 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{card.body}</p>
              </div>
            ))}
          </div>
        </AirContainer>
      </section>
    </AirPage>
  );
}
