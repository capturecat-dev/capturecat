import {
  Rocket,
  Bug,
  GraduationCap,
  Smartphone,
  Users,
  PenTool,
} from "lucide-react";

import { Container, GlassCard, IconTile, SectionTitle } from "../primitives";
import { SpotlightGroup } from "../SpotlightGroup";

const CASES = [
  {
    icon: Rocket,
    title: "Launch videos",
    body: "Record the feature once, export 16:9 for the landing page and 9:16 for social. The zooms follow the same click data in both.",
  },
  {
    icon: Bug,
    title: "Bug reports",
    body: "Hit the global shortcut, reproduce the bug, stop. The keystroke pill and click ripples show exactly what you did. Paste the link in the ticket.",
  },
  {
    icon: GraduationCap,
    title: "Tutorials and docs",
    body: "Captions come from your narration. Blur the account details. Speed regions skip the loading spinners you would otherwise cut by hand.",
  },
  {
    icon: Smartphone,
    title: "iPhone and iPad demos",
    body: "Plug the phone in, record it, and export inside a photoreal bezel on a wallpaper. Tap indicators show where your finger went.",
  },
  {
    icon: Users,
    title: "Async updates for the team",
    body: "Camera bubble, name tag, a share link, and comments pinned to the second where someone has a question.",
  },
  {
    icon: PenTool,
    title: "Design reviews",
    body: "Spotlight the component under discussion, dim the rest, and drop an arrow on the pixel that is off. Viewers reply at the exact frame.",
  },
];

export default function UseCases() {
  return (
    <section className="relative isolate py-24">
      <Container>
        <SectionTitle className="scroll-reveal" muted="The same recorder, pointed at different jobs.">
          What people record with it
        </SectionTitle>
        <SpotlightGroup className="mt-12 grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
          {CASES.map((c) => (
            <GlassCard key={c.title} spot padding="p-7" className="scroll-reveal">
              <IconTile>
                <c.icon className="h-[18px] w-[18px]" strokeWidth={1.75} />
              </IconTile>
              <h3 className="mt-5 text-[17px] font-medium tracking-[-0.01em] text-foreground">
                {c.title}
              </h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">{c.body}</p>
            </GlassCard>
          ))}
        </SpotlightGroup>
      </Container>
    </section>
  );
}
