/**
 * Chips (InspectorChipsControl), Toggle (CCToggle), Segmented (CCSegmented).
 */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
} from "react";

// ── Chips ───────────────────────────────────────────────────────────────

const CHIP_DEFAULT_PAD = 14;
const CHIP_MIN_PAD = 8;
const CHIP_GAP = 8;

/**
 * A row of roomy pill chips. Padding compresses (14 → 8pt per side) until the
 * whole set fits one line; only then does it WRAP (6pt row gap) — a chip cut
 * mid-label reads as broken, never as scrollable. Selected = the active wash,
 * raised; no selection ring.
 */
export function Chips({
  items,
  selectedIndex,
  onSelect,
  ariaLabel,
}: {
  items: readonly string[];
  selectedIndex: number;
  onSelect: (index: number) => void;
  ariaLabel?: string;
}) {
  const rowRef = useRef<HTMLDivElement>(null);
  const measureRef = useRef<HTMLDivElement>(null);
  const [pad, setPad] = useState(CHIP_DEFAULT_PAD);

  const recompute = useCallback(() => {
    const row = rowRef.current;
    const measure = measureRef.current;
    if (!row || !measure) return;
    const width = row.clientWidth;
    let labelTotal = 0;
    for (const child of Array.from(measure.children)) labelTotal += (child as HTMLElement).getBoundingClientRect().width;
    const gaps = CHIP_GAP * Math.max(0, items.length - 1);
    const perSide = Math.floor((width - gaps - labelTotal) / Math.max(1, items.length * 2));
    setPad(Math.min(CHIP_DEFAULT_PAD, Math.max(CHIP_MIN_PAD, perSide)));
  }, [items.length]);

  useLayoutEffect(() => {
    recompute();
    const row = rowRef.current;
    if (!row) return;
    const ro = new ResizeObserver(recompute);
    ro.observe(row);
    void document.fonts?.ready.then(recompute);
    return () => ro.disconnect();
  }, [recompute, items]);

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === "ArrowRight" || e.key === "ArrowDown") {
      e.preventDefault();
      onSelect(Math.min(items.length - 1, selectedIndex + 1));
    } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
      e.preventDefault();
      onSelect(Math.max(0, selectedIndex - 1));
    }
  };

  return (
    <div
      ref={rowRef}
      className="cc-chips"
      role="radiogroup"
      aria-label={ariaLabel}
      onKeyDown={onKeyDown}
      style={{ "--chips-pad": `${pad}px`, position: "relative" } as CSSProperties}
    >
      <div ref={measureRef} aria-hidden style={{ position: "absolute", visibility: "hidden", display: "flex" }}>
        {items.map((label) => (
          <span key={label} className="cc-chip-measure" style={{ position: "static" }}>
            {label}
          </span>
        ))}
      </div>
      {items.map((label, index) => (
        <button
          key={label}
          type="button"
          role="radio"
          aria-checked={index === selectedIndex}
          tabIndex={index === selectedIndex ? 0 : -1}
          className="cc-chip cc-mat-raised cc-press"
          onClick={() => {
            if (index !== selectedIndex) onSelect(index);
          }}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

// ── Toggle ──────────────────────────────────────────────────────────────

/**
 * CCToggle — a lit recessed track (primary when on, active wash when off) and
 * a raised white ball that springs across on the house BOUNCY spring. Flips
 * on press-down: switches should feel instant.
 *
 * `size="sm"` is CaptureCatToggle, the inspector's compact switch: 30×18
 * track (accent .88 on / elevated + hairline off), 12pt ball at 3 → 15.
 */
export function Toggle({
  checked,
  onChange,
  disabled,
  ariaLabel,
  size = "regular",
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
  ariaLabel?: string;
  size?: "sm" | "regular";
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={ariaLabel}
      disabled={disabled}
      className="cc-toggle cc-mat-recessed cc-mat-pill"
      data-size={size === "sm" ? "sm" : undefined}
      onPointerDown={(e) => {
        if (e.button !== 0 || disabled) return;
        e.preventDefault();
        onChange(!checked);
      }}
      onClick={(e) => {
        // Keyboard activation (Space/Enter) arrives as a detail-0 click.
        if (e.detail === 0 && !disabled) onChange(!checked);
      }}
    >
      <span className="cc-toggle__thumb cc-mat-raised cc-mat-short" />
    </button>
  );
}

/** Label left, toggle right (InspectorToggleControl: the compact
 *  CaptureCatToggle; disabled dims the label to .4, the switch to .38). */
export function ToggleRow({
  label,
  checked,
  onChange,
  disabled,
}: {
  label: string;
  checked: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <div className="cc-row">
      <span className="cc-row__label" style={disabled ? { opacity: 0.4 } : undefined}>
        {label}
      </span>
      <Toggle checked={checked} onChange={onChange} disabled={disabled} ariaLabel={label} size="sm" />
    </div>
  );
}

// ── Segmented ───────────────────────────────────────────────────────────

/**
 * CCSegmented — equal-width segments in a recessed well with a raised
 * selection chip that SPRINGS (snappy) between them. `.plain` chrome is the
 * title-bar look: bare at rest, the selection a quiet raised ink wash.
 * Optional glide hover wash (never over the selected segment).
 */
export function Segmented({
  segments,
  selectedIndex,
  onChange,
  size = "regular",
  chrome = "elevated",
  radius = "md",
  hoverWash = false,
  disabled,
  ariaLabel,
}: {
  segments: readonly string[];
  selectedIndex: number;
  onChange: (index: number) => void;
  size?: "sm" | "regular";
  chrome?: "elevated" | "plain";
  radius?: "md" | "full";
  hoverWash?: boolean;
  disabled?: boolean;
  ariaLabel?: string;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const inset = size === "sm" ? 2 : 3;
  const height = size === "sm" ? 24 : 30;
  const outer = radius === "full" ? height / 2 : 6;
  const chipRadius = radius === "md" ? 4 : Math.max(outer - inset, 2);
  const hoverIndex = hover != null && hover !== selectedIndex ? hover : null;
  // Glide rules (CCGlideHighlight): appear IN PLACE when faded out, spring
  // between segments while visible, fade out where it stands.
  const visibleRef = useRef(false);
  const lastHoverRef = useRef(0);
  const appearing = hoverIndex != null && !visibleRef.current;
  const washIndex = hoverIndex ?? lastHoverRef.current;
  useEffect(() => {
    visibleRef.current = hoverIndex != null;
    if (hoverIndex != null) lastHoverRef.current = hoverIndex;
  });

  const style = {
    "--seg-n": segments.length,
    "--seg-i": selectedIndex,
    "--seg-radius": `${outer}px`,
    "--seg-chip-radius": `${chipRadius}px`,
    opacity: disabled ? "var(--cc-disabled-alpha)" : undefined,
  } as CSSProperties;

  const chipGeometry: CSSProperties = {
    left: `calc(var(--seg-inset) - 1px)`,
    width: `calc((100% + 2px - 2 * var(--seg-inset)) / var(--seg-n))`,
  };

  return (
    <div
      className={`cc-seg${chrome === "elevated" ? " cc-mat-recessed" : ""}`}
      data-size={size}
      data-chrome={chrome}
      role="radiogroup"
      aria-label={ariaLabel}
      style={{ ...style, padding: `0 calc(var(--seg-inset) - 1px)` }}
      onPointerLeave={() => setHover(null)}
      onKeyDown={(e) => {
        if (disabled) return;
        if (e.key === "ArrowRight") onChange(Math.min(segments.length - 1, selectedIndex + 1));
        if (e.key === "ArrowLeft") onChange(Math.max(0, selectedIndex - 1));
      }}
    >
      {hoverWash && (
        <span
          className="cc-seg__hover"
          style={{
            ...chipGeometry,
            transform: `translateX(calc(${washIndex} * 100%))`,
            opacity: hoverIndex != null ? 1 : 0,
            transition: appearing ? "opacity 100ms var(--cc-ease-glide)" : undefined,
          }}
        />
      )}
      <span
        className="cc-seg__chip cc-mat-raised cc-mat-short"
        style={{ ...chipGeometry, transform: `translateX(calc(var(--seg-i) * 100%))` }}
      />
      {segments.map((label, index) => (
        <button
          key={label}
          type="button"
          role="radio"
          aria-checked={index === selectedIndex}
          tabIndex={index === selectedIndex ? 0 : -1}
          disabled={disabled}
          className="cc-seg__item"
          onPointerEnter={() => hoverWash && setHover(index)}
          onPointerDown={(e) => {
            if (e.button !== 0 || disabled) return;
            if (index !== selectedIndex) onChange(index);
          }}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
