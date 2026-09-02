import { Link2, BarChart3, MessageSquare, Lock } from "lucide-react";

import { MediaPlaceholder } from "../MediaPlaceholder";
import { Container, Eyebrow, GlassCard, IconTile, Lede, SectionTitle } from "../primitives";
import { SpotlightGroup } from "../SpotlightGroup";

const POINTS = [
  {
    icon: Link2,
    title: "Upload from the app",
    body: "No export, no browser tab, no drag into a web form. The link is on your clipboard when the progress bar fills.",
  },
  {
    icon: Lock,
    title: "Public or private, flip any time",
    body: "Private links need a sign in to view. You can also turn a link off entirely and turn it back on later.",
  },
  {
    icon: MessageSquare,
    title: "Comments pinned to the second",
    body: "A viewer clicks the timeline and types. You get the comment with a timestamp, and clicking it seeks the player there.",
  },
  {
    icon: BarChart3,
    title: "See where people stopped",
    body: "Views, watch time, the retention curve, and which player controls were clicked. If most viewers leave at 0:42, you know what to trim.",
  },
];

export default function ShareSection() {
  return (
    <section id="share" className="relative isolate py-24">
      <Container>
        <div className="scroll-reveal flex flex-col items-start gap-4">
          <Eyebrow>Pro plan</Eyebrow>
          <SectionTitle muted="With the numbers a YouTube upload never shows you.">
            Send a link instead of a file.
          </SectionTitle>
          <Lede>
            Recording and exporting are free forever. Pro adds the hosted part:
            share pages on capturecat.so, comments, and per video analytics.
          </Lede>
        </div>

        <div className="mt-12 grid grid-cols-1 gap-6 lg:grid-cols-2">
          <div className="scroll-reveal">
            <MediaPlaceholder id="share-page" />
            <p className="mt-3 text-sm text-muted-foreground">A share page, with comments.</p>
          </div>
          <div className="scroll-reveal">
            <MediaPlaceholder id="share-analytics" />
            <p className="mt-3 text-sm text-muted-foreground">
              The analytics tab for the same video.
            </p>
          </div>
        </div>

        <SpotlightGroup className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-4">
          {POINTS.map((p) => (
            <GlassCard key={p.title} spot padding="p-7" className="scroll-reveal">
              <IconTile>
                <p.icon className="h-[18px] w-[18px]" strokeWidth={1.75} />
              </IconTile>
              <h3 className="mt-5 text-[17px] font-medium tracking-[-0.01em] text-foreground">
                {p.title}
              </h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">{p.body}</p>
            </GlassCard>
          ))}
        </SpotlightGroup>
      </Container>
    </section>
  );
}
