import { createFileRoute } from "@tanstack/react-router";
import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import { DownloadButtons } from "@/components/marketing/download-buttons";
import { API_URL } from "@/lib/api-url";
import { markdownAlternateLinks } from "@/lib/site-content";

async function getLatestRelease() {
  try {
    const res = await fetch(`${API_URL}/api/releases/latest`);
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
    meta: [{ title: "Download CaptureCat for macOS | CaptureCat" }],
    links: markdownAlternateLinks("/download"),
  }),
  component: DownloadPage,
});

function DownloadPage() {
  const { release } = Route.useLoaderData();

  return (
    <main className="min-h-screen bg-background flex flex-col">
      <Navbar />
      <section className="flex-1 flex flex-col items-center justify-center px-4 py-24">
        <div className="text-center space-y-8 max-w-2xl animate-fade-up">
          <h1 className="text-4xl md:text-6xl font-bold tracking-tight text-foreground">
            Download CaptureCat
          </h1>
          <p className="text-lg text-muted-foreground">
            Screen recording, editing, and sharing — built natively for macOS.
          </p>

          {release ? (
            <>
              <DownloadButtons release={release} />
              <p className="text-sm text-muted-foreground pt-2">
                Requires macOS Sonoma 14.0 or later
              </p>
            </>
          ) : (
            <p className="text-lg text-muted-foreground">
              Coming soon. Stay tuned.
            </p>
          )}
        </div>
      </section>
      <Footer />
    </main>
  );
}
