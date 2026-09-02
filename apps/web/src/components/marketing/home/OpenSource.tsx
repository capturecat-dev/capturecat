import { Container, Eyebrow, GlassCard, GITHUB_URL, GitHubIcon, SecondaryAnchor, SectionTitle } from "../primitives";

const REPO_PARTS = [
  {
    title: "apps/macos",
    body: "The whole Mac app in Swift and AppKit: recorder, editor, exporter, the MCP server, and the parity harnesses that prove the preview matches the export.",
  },
  {
    title: "apps/api",
    body: "The sharing backend on Cloudflare Workers: uploads, share pages, comments, analytics, and billing. Self host it if you would rather not use ours.",
  },
  {
    title: "apps/web",
    body: "This site, the share player, and the dashboard. Every page you are reading, including the one that says this.",
  },
];

export default function OpenSource() {
  return (
    <section id="open-source" className="relative isolate py-24">
      <Container>
        <div className="grid grid-cols-1 items-start gap-10 lg:grid-cols-12 lg:gap-14">
          <div className="scroll-reveal lg:col-span-5">
            <Eyebrow>Open source</Eyebrow>
            <SectionTitle className="mt-5" muted="Licensed under the AGPL-3.0.">
              Every line is on GitHub.
            </SectionTitle>
            <p className="mt-5 text-[15.5px] leading-relaxed text-muted-foreground">
              The app, the API, and this website live in one public
              repository. Read how auto zoom decides where to push in, check
              what the analytics actually record, build the app from source, or
              run the sharing side on your own Cloudflare account. Pro pays for
              the hosted service, not for access to the code.
            </p>
            <p className="mt-4 text-[15.5px] leading-relaxed text-muted-foreground">
              Bugs and feature requests go in GitHub issues. Pull requests are
              read by the person who wrote the code you are changing.
            </p>
            <div className="mt-7 flex flex-wrap gap-3">
              <SecondaryAnchor href={GITHUB_URL} target="_blank" rel="noopener">
                <GitHubIcon />
                capturecat-dev/capturecat
              </SecondaryAnchor>
            </div>
          </div>
          <div className="scroll-reveal grid grid-cols-1 gap-4 lg:col-span-7">
            {REPO_PARTS.map((part) => (
              <GlassCard key={part.title} padding="p-6">
                <code className="text-sm font-medium text-foreground">{part.title}</code>
                <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                  {part.body}
                </p>
              </GlassCard>
            ))}
          </div>
        </div>
      </Container>
    </section>
  );
}
