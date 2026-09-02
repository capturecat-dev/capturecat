import { Link } from "@tanstack/react-router";
import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { TiltCard } from "./TiltCard";

export default function Hero() {
  return (
    <section className="relative isolate overflow-hidden">
      {/* Ambient light — glass needs something to catch */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-10"
        style={{
          background:
            "radial-gradient(120% 80% at 50% -20%, rgba(120,140,255,0.22), transparent 60%)," +
            "radial-gradient(90% 60% at 85% 10%, rgba(80,220,255,0.14), transparent 55%)," +
            "radial-gradient(70% 50% at 10% 30%, rgba(190,120,255,0.12), transparent 60%)",
        }}
      />

      <div className="mx-auto max-w-6xl px-6 pb-20 pt-10 md:pt-14">
        <div className="flex flex-col items-center text-center">
          <CaptureCatMark
            animated
            className="cc-float h-16 w-16 drop-shadow-[0_12px_40px_rgba(0,0,0,0.55)] md:h-20 md:w-20"
          />

          <Link
            to="/agents"
            className="group mt-6 inline-flex items-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-4 py-1.5 text-[13px] text-muted-foreground backdrop-blur-xl transition-colors hover:border-white/20 hover:text-foreground"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
            New — your AI agent can drive CaptureCat too
            <span aria-hidden className="transition-transform group-hover:translate-x-0.5">
              →
            </span>
          </Link>

          <h1 className="mt-6 max-w-4xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] text-foreground md:text-7xl">
            Screen recordings that look{" "}
            <span className="bg-gradient-to-b from-white to-white/55 bg-clip-text text-transparent">
              purrfect.
            </span>
          </h1>

          <p className="mt-5 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground md:text-xl">
            CaptureCat is a screen recorder for Mac that edits itself —
            cinematic zooms, a steadied cursor, real captions, and an export
            that matches the preview exactly.
          </p>

          <div className="mt-8 flex flex-col items-center gap-3 sm:flex-row">
            <Link
              to="/download"
              className="group relative inline-flex h-12 items-center justify-center gap-2 overflow-hidden rounded-full bg-white px-7 text-[15px] font-medium text-black shadow-[0_8px_30px_rgba(0,0,0,0.35)] transition-transform duration-300 hover:scale-[1.02] active:scale-[0.99]"
            >
              <svg className="h-[18px] w-[18px]" viewBox="0 0 842.32 1000" fill="currentColor" aria-hidden>
                <path d="M824.66636 779.30363c-15.12299 34.93724-33.02368 67.09674-53.7638 96.66374-28.27076 40.3074-51.4182 68.2078-69.25717 83.7012-27.65347 25.4313-57.2822 38.4556-89.00964 39.1963-22.77708 0-50.24539-6.4813-82.21973-19.629-32.07926-13.0861-61.55985-19.5673-88.51583-19.5673-28.27075 0-58.59083 6.4812-91.02193 19.5673-32.48053 13.1477-58.64639 19.9994-78.65196 20.6784-30.42501 1.29623-60.75123-12.0985-91.02193-40.2457-19.32039-16.8514-43.48632-45.7394-72.43607-86.6641-31.060778-43.7024-56.597041-94.37983-76.602609-152.15586C10.740416 658.44309 0 598.01283 0 539.50845c0-67.01648 14.481044-124.8172 43.486336-173.25401C66.28194 327.34823 96.60818 296.6578 134.5638 274.1276c37.95566-22.53016 78.96676-34.01129 123.1321-34.74585 24.16591 0 55.85633 7.47508 95.23784 22.166 39.27042 14.74029 64.48571 22.21538 75.54091 22.21538 8.26518 0 36.27668-8.7405 83.7629-26.16587 44.90607-16.16001 82.80614-22.85118 113.85458-20.21546 84.13326 6.78992 147.34122 39.95559 189.37699 99.70686-75.24463 45.59122-112.46573 109.4473-111.72502 191.36456.67899 63.8067 23.82643 116.90384 69.31888 159.06309 20.61664 19.56727 43.64066 34.69027 69.2571 45.4307-5.55531 16.11062-11.41933 31.54225-17.65372 46.35662zM631.70926 20.0057c0 50.01141-18.27108 96.70693-54.6897 139.92782-43.94932 51.38118-97.10817 81.07162-154.75459 76.38659-.73454-5.99983-1.16045-12.31444-1.16045-18.95003 0-48.01091 20.9006-99.39207 58.01678-141.40314 18.53027-21.27094 42.09746-38.95744 70.67685-53.0663C578.3158 9.00229 605.2903 1.31621 630.65988 0c.74076 6.68575 1.04938 13.37191 1.04938 20.00505z" />
              </svg>
              Download for Mac
            </Link>

            <Link
              to="." hash="features"
              className="inline-flex h-12 items-center justify-center rounded-full border border-white/12 bg-white/[0.06] px-7 text-[15px] font-medium text-foreground backdrop-blur-xl transition-colors duration-300 hover:border-white/20 hover:bg-white/[0.10]"
            >
              See what it does
            </Link>
          </div>

        </div>

        {/* Placeholder for a product recording the owner will supply —
            the glass frame stays so the hero keeps its depth, showing the
            canvas gradient the app itself ships with. */}
        <div className="relative mt-12 md:mt-16">
          <div
            aria-hidden
            className="absolute -inset-x-8 -top-8 bottom-10 -z-10 rounded-[3rem] bg-gradient-to-b from-white/[0.07] to-transparent blur-2xl"
          />
          <TiltCard className="relative overflow-hidden rounded-[28px] border border-white/12 bg-white/[0.04] p-2 shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] backdrop-blur-2xl">
            <span
              aria-hidden
              className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
            />
            <div className="relative aspect-video overflow-hidden rounded-[22px] bg-[#0e0e10]">
              <div
                className="absolute inset-0"
                style={{
                  background:
                    "linear-gradient(135deg, #ff5f9e 0%, #7c5cff 45%, #2fb8ff 100%)",
                }}
              />
              <div className="absolute inset-x-0 bottom-6 flex justify-center">
                <span className="cc-demo-caption rounded-md bg-black/55 px-3 py-1.5 text-sm font-semibold text-white backdrop-blur-sm">
                  This is the part that used to take an hour.
                </span>
              </div>
            </div>
          </TiltCard>
        </div>
      </div>
    </section>
  );
}
