import { IOS_APP_STORE_URL } from "@/lib/ios-app";
import { AppleGlyph } from "../primitives";

/**
 * A real app screenshot from public/media: AVIF and WebP with a PNG fallback.
 * Decorative inside a device frame (the composition carries the label).
 */
export function ScreenPicture({
  name,
  width,
  height,
  priority = false,
  className,
}: {
  /** Basename in /media (no extension). */
  name: string;
  width: number;
  height: number;
  priority?: boolean;
  className?: string;
}) {
  return (
    <picture className={className}>
      <source srcSet={`/media/${name}.avif`} type="image/avif" />
      <source srcSet={`/media/${name}.webp`} type="image/webp" />
      <img
        src={`/media/${name}.png`}
        alt=""
        width={width}
        height={height}
        decoding="async"
        loading={priority ? "eager" : "lazy"}
        fetchPriority={priority ? "high" : "auto"}
      />
    </picture>
  );
}

/**
 * The iPhone app's real UI: a project open in the app (fixture mode on the
 * simulator, `-uiFixtureScreen project`), 603 × 1311.
 */
export function IosAppScreen({ priority = false }: { priority?: boolean }) {
  return <ScreenPicture name="ios-app-project" width={603} height={1311} priority={priority} />;
}

/**
 * The iPad app's real UI: the library filtered to videos beside a project
 * (fixture mode, landscape), 1100 × 758.
 */
export function IpadAppScreen({ priority = false }: { priority?: boolean }) {
  return <ScreenPicture name="ipad-app-library" width={1100} height={758} priority={priority} />;
}

/**
 * The studio editor on the unfolded foldable: split at the vertical crease,
 * the stage on one half, timeline and inspector on the other (the
 * `splitAtVerticalCrease` arrangement, captured through the crease seam),
 * 900 × 633.
 */
export function FoldableEditorScreen({ priority = false }: { priority?: boolean }) {
  return <ScreenPicture name="foldable-editor-split" width={900} height={633} priority={priority} />;
}

/** The App Store link. */
export function AppStoreSlot({ className = "mt-4" }: { className?: string }) {
  return (
    <a
      href={IOS_APP_STORE_URL}
      className={`${className} inline-flex h-11 items-center gap-2 rounded-full bg-[var(--cc-air-ink)] px-5 text-[15px] font-medium text-white shadow-[inset_0_1px_0_rgb(255_255_255/0.14),0_8px_20px_-10px_rgb(0_0_0/0.55)] transition-transform hover:-translate-y-px`}
    >
      <AppleGlyph />
      Download on the App Store
    </a>
  );
}
