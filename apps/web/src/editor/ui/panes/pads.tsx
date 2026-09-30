/**
 * Background pane pads:
 *  • PlacementPad — PlacementPadControl (a CCPreviewPad): 3×3 anchor dots +
 *    the mini card; click/drag snaps to the nine placements; the inset
 *    tracks Padding; a freeform placement shows the card where it really is.
 *  • WallpaperGrid — WallpaperGridControl: 3×2 paginated tiles (catalog), or
 *    the user's own image library (images), each tile with the Mac's
 *    right-click menu. The macOS wallpaper catalog is a local-disk scan (and
 *    Apple's CDN) with no web equivalent, so a catalog with no items shows
 *    the host's `empty` state instead (BackgroundPane: the project's own
 *    wallpaper, the image library, Choose Image…).
 */
import { useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";

import type { VideoPlacement } from "../../core/model";
import { Caption, ContextMenu, QuietButton, type MenuEntry } from "../kit";

const FRACTIONS: Record<VideoPlacement, [number, number]> = {
  "Top Left": [0, 0],
  Top: [0.5, 0],
  "Top Right": [1, 0],
  Left: [0, 0.5],
  Center: [0.5, 0.5],
  Right: [1, 0.5],
  "Bottom Left": [0, 1],
  Bottom: [0.5, 1],
  "Bottom Right": [1, 1],
};

export function PlacementPad({
  placement,
  custom,
  padding,
  onSelect,
}: {
  placement: VideoPlacement;
  custom: { x: number; y: number } | null;
  padding: number;
  onSelect: (p: VideoPlacement) => void;
}) {
  const padRef = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 245, h: 96 });
  useLayoutEffect(() => {
    const el = padRef.current;
    if (!el) return;
    const measure = () => setSize({ w: el.offsetWidth, h: el.offsetHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const inset = 6 + (Math.min(Math.max(padding, 0), 300) / 300) * Math.min(size.w, size.h) * 0.28;
  const cw = Math.max(1, size.w - 2 * inset);
  const ch = Math.max(1, size.h - 2 * inset);
  const cardW = cw * 0.5;
  const cardH = ch * 0.58;
  let cardX: number;
  let cardY: number;
  if (custom) {
    const fx = Math.min(1, Math.max(0, custom.x));
    const fy = Math.min(1, Math.max(0, custom.y));
    cardX = inset + cw * fx - cardW / 2;
    cardY = inset + ch * fy - cardH / 2;
  } else {
    const [fx, fy] = FRACTIONS[placement] ?? [0.5, 0.5];
    cardX = inset + (cw - cardW) * fx;
    cardY = inset + (ch - cardH) * fy;
  }

  const pick = (e: ReactPointerEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const step = (f: number) => (f < 1 / 3 ? 0 : f > 2 / 3 ? 1 : 0.5);
    const fx = step((e.clientX - r.left) / Math.max(1, r.width));
    const fy = step((e.clientY - r.top) / Math.max(1, r.height));
    const match = (Object.keys(FRACTIONS) as VideoPlacement[]).find((k) => FRACTIONS[k][0] === fx && FRACTIONS[k][1] === fy);
    if (match && (match !== placement || custom)) onSelect(match);
  };

  return (
    <div
      ref={padRef}
      className="cc-pad cc-mat-recessed"
      role="radiogroup"
      aria-label="Placement"
      onPointerDown={(e) => {
        if (e.button !== 0) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        pick(e);
      }}
      onPointerMove={(e) => e.buttons === 1 && pick(e)}
    >
      {Object.values(FRACTIONS).map(([fx, fy], i) => (
        <span key={i} className="cc-pad__dot" style={{ left: inset + cw * fx - 1, top: inset + ch * fy - 1 }} />
      ))}
      <span className="cc-pad__card" style={{ left: cardX - 1, top: cardY - 1, width: cardW, height: cardH }} />
    </div>
  );
}

export interface WallpaperItem {
  /** The value written to backgroundImagePath when picked. */
  path: string;
  name: string;
  thumbnailUrl?: string;
}

const PAGE = 6;

/** WallpaperCell: thumbnail fill-crop, selection ring, right-click menu (Set as Default / Remove from Library). */
export function WallpaperTiles({
  items,
  selected,
  onSelect,
  menuFor,
}: {
  items: readonly WallpaperItem[];
  selected: string | null;
  onSelect: (item: WallpaperItem) => void;
  menuFor?: (item: WallpaperItem) => MenuEntry[] | null;
}) {
  const [menu, setMenu] = useState<{ at: { x: number; y: number }; entries: MenuEntry[] } | null>(null);
  return (
    <>
      <div className="cc-wallgrid__tiles">
        {items.map((item) => (
          <button
            key={item.path}
            type="button"
            className="cc-wallgrid__tile"
            title={item.name}
            aria-label={item.name}
            aria-pressed={selected === item.path}
            style={item.thumbnailUrl ? { backgroundImage: `url("${item.thumbnailUrl}")` } : undefined}
            onPointerDown={(e) => e.button === 0 && onSelect(item)}
            onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), onSelect(item))}
            onContextMenu={(e) => {
              const entries = menuFor?.(item);
              if (!entries?.length) return;
              e.preventDefault();
              setMenu({ at: { x: e.clientX, y: e.clientY }, entries });
            }}
          />
        ))}
      </div>
      {menu && <ContextMenu at={menu.at} entries={menu.entries} onDismiss={() => setMenu(null)} />}
    </>
  );
}

export function WallpaperGrid({
  mode,
  items = [],
  selected,
  onSelect,
  menuFor,
  empty,
}: {
  mode: "catalog" | "images";
  items?: readonly WallpaperItem[];
  selected: string | null;
  onSelect: (path: string) => void;
  menuFor?: (item: WallpaperItem) => MenuEntry[] | null;
  /** Catalog with no system wallpapers (the web): what to show instead. */
  empty?: ReactNode;
}) {
  const [page, setPage] = useState(0);
  const pickItem = (item: WallpaperItem) => onSelect(item.path);
  if (mode === "images") {
    // `.customImages`: only the user's library — no pager, no captions.
    if (items.length === 0) return null;
    return (
      <div className="cc-wallgrid">
        <WallpaperTiles items={items} selected={selected} onSelect={pickItem} menuFor={menuFor} />
      </div>
    );
  }
  if (items.length === 0 && empty !== undefined) return <>{empty}</>;
  const pages = Math.max(1, Math.ceil(items.length / PAGE));
  const p = Math.min(page, pages - 1);
  const visible = items.slice(p * PAGE, p * PAGE + PAGE);
  return (
    <div className="cc-wallgrid">
      {items.length === 0 ? (
        <Caption>No system wallpapers found</Caption>
      ) : (
        <WallpaperTiles items={visible} selected={selected} onSelect={pickItem} menuFor={menuFor} />
      )}
      <div className="cc-wallgrid__pager">
        <QuietButton symbol="chevron.left" height={26} paddingX={4} style={{ opacity: p === 0 ? 0.3 : 0.8 }} onClick={() => setPage(Math.max(0, p - 1))} />
        <span className="cc-caption">
          {p + 1} / {pages}
        </span>
        <QuietButton symbol="chevron.right" height={26} paddingX={4} style={{ opacity: p >= pages - 1 ? 0.3 : 0.8 }} onClick={() => setPage(Math.min(pages - 1, p + 1))} />
      </div>
      {items.length > 0 && <Caption>Wallpapers with a download badge fetch in full quality on first use.</Caption>}
    </div>
  );
}
