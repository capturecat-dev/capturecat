import { useEffect, useState } from "react";

import { API_URL } from "@/lib/api-url";

function AppleLogo({ className }: { className?: string }) {
  return (
    <svg
      className={className}
      viewBox="0 0 842.32 1000"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M824.66636 779.30363c-15.12299 34.93724-33.02368 67.09674-53.7638 96.66374-28.27076 40.3074-51.4182 68.2078-69.25717 83.7012-27.65347 25.4313-57.2822 38.4556-89.00964 39.1963-22.77708 0-50.24539-6.4813-82.21973-19.629-32.07926-13.0861-61.55985-19.5673-88.51583-19.5673-28.27075 0-58.59083 6.4812-91.02193 19.5673-32.48053 13.1477-58.64639 19.9994-78.65196 20.6784-30.42501 1.29623-60.75123-12.0985-91.02193-40.2457-19.32039-16.8514-43.48632-45.7394-72.43607-86.6641-31.060778-43.7024-56.597041-94.37983-76.602609-152.15586C10.740416 658.44309 0 598.01283 0 539.50845c0-67.01648 14.481044-124.8172 43.486336-173.25401C66.28194 327.34823 96.60818 296.6578 134.5638 274.1276c37.95566-22.53016 78.96676-34.01129 123.1321-34.74585 24.16591 0 55.85633 7.47508 95.23784 22.166 39.27042 14.74029 64.48571 22.21538 75.54091 22.21538 8.26518 0 36.27668-8.7405 83.7629-26.16587 44.90607-16.16001 82.80614-22.85118 113.85458-20.21546 84.13326 6.78992 147.34122 39.95559 189.37699 99.70686-75.24463 45.59122-112.46573 109.4473-111.72502 191.36456.67899 63.8067 23.82643 116.90384 69.31888 159.06309 20.61664 19.56727 43.64066 34.69027 69.2571 45.4307-5.55531 16.11062-11.41933 31.54225-17.65372 46.35662zM631.70926 20.0057c0 50.01141-18.27108 96.70693-54.6897 139.92782-43.94932 51.38118-97.10817 81.07162-154.75459 76.38659-.73454-5.99983-1.16045-12.31444-1.16045-18.95003 0-48.01091 20.9006-99.39207 58.01678-141.40314 18.53027-21.27094 42.09746-38.95744 70.67685-53.0663C578.3158 9.00229 605.2903 1.31621 630.65988 0c.74076 6.68575 1.04938 13.37191 1.04938 20.00505z" />
    </svg>
  );
}

type Arch = "arm64" | "x86_64" | null;

function useDetectedArch(): Arch {
  const [arch, setArch] = useState<Arch>(null);

  useEffect(() => {
    const ua = navigator.userAgent.toLowerCase();
    // Apple Silicon Macs don't report arm in UA, but we can check via WebGL renderer
    // or platform. Safari on Apple Silicon reports "MacIntel" but we can use a canvas trick.
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl");
    const renderer = gl
      ? gl.getParameter(gl.getExtension("WEBGL_debug_renderer_info")?.UNMASKED_RENDERER_WEBGL ?? gl.RENDERER)
      : "";

    if (
      ua.includes("arm64") ||
      ua.includes("aarch64") ||
      /apple m\d/i.test(renderer) ||
      /apple gpu/i.test(renderer)
    ) {
      setArch("arm64");
    } else if (ua.includes("mac")) {
      // Default Intel for older Macs, but Apple Silicon is more common now
      // Check if running under Rosetta - not easily detectable, so we default to arm64
      // since most Macs sold since late 2020 are Apple Silicon
      setArch("arm64");
    }
  }, []);

  return arch;
}

interface Release {
  version: string;
  date: string;
  minOS: string;
  notes: string;
  downloads: { arm64: string; x86_64: string };
}

export function DownloadButtons({ release }: { release: Release | null }) {
  const armUrl = `${API_URL}/api/releases/download/arm64`;
  const intelUrl = `${API_URL}/api/releases/download/x86_64`;
  const detectedArch = useDetectedArch();

  const isAppleSilicon = detectedArch === "arm64";

  return (
    <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-4">
      <a
        href={armUrl}
        className={`inline-flex h-12 items-center justify-center rounded-full px-8 text-sm font-medium shadow transition-all hover:scale-105 active:scale-95 duration-300 gap-2 ${
          isAppleSilicon
            ? "bg-white text-black hover:bg-white/90"
            : "border border-white/20 bg-background/50 backdrop-blur-sm text-foreground hover:bg-white/10 hover:text-white"
        }`}
      >
        <AppleLogo className="h-4 w-4" />
        Download for Apple Silicon
      </a>
      <a
        href={intelUrl}
        className={`inline-flex h-12 items-center justify-center rounded-full px-8 text-sm font-medium shadow transition-all hover:scale-105 active:scale-95 duration-300 gap-2 ${
          !isAppleSilicon && detectedArch !== null
            ? "bg-white text-black hover:bg-white/90"
            : "border border-white/20 bg-background/50 backdrop-blur-sm text-foreground hover:bg-white/10 hover:text-white"
        }`}
      >
        <AppleLogo className="h-4 w-4" />
        Download for Intel
      </a>
    </div>
  );
}
