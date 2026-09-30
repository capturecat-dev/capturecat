/**
 * Menu list, Select/Combobox (CCCombobox + CCSelect + InspectorMenuControl)
 * and ContextMenu.
 *
 * One list surface everywhere: popover-tinted card (radius lg, hairline,
 * soft 18pt shadow), 30pt rows, a single glide wash that follows the pointer
 * AND the keyboard, trailing selection check (house rule: check far right).
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import { Floating, GlideWash, rectOf, useGlide, type AnchorRect, type Edge } from "./Floating";
import { SFIcon } from "./icons";

export interface MenuItem {
  title: string;
  subtitle?: string;
  checked?: boolean;
  disabled?: boolean;
  destructive?: boolean;
  onSelect?: () => void;
}
export type MenuEntry = MenuItem | "separator";

export function MenuList({
  entries,
  onClose,
  searchable = false,
  searchPlaceholder = "Search…",
  emptyText = "No results",
  autoFocus = true,
}: {
  entries: MenuEntry[];
  onClose: () => void;
  searchable?: boolean;
  searchPlaceholder?: string;
  emptyText?: string;
  autoFocus?: boolean;
}) {
  const glide = useGlide();
  const [query, setQuery] = useState("");
  const [active, setActive] = useState<number | null>(null);
  const rowRefs = useRef<(HTMLDivElement | null)[]>([]);
  const listRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return entries
      .map((entry, index) => ({ entry, index }))
      .filter(({ entry }) =>
        entry === "separator" ? !q : !q || entry.title.toLowerCase().includes(q) || entry.subtitle?.toLowerCase().includes(q),
      );
  }, [entries, query]);

  const selectable = visible.filter(({ entry }) => entry !== "separator" && !entry.disabled);

  useEffect(() => {
    if (!autoFocus) return;
    (searchable ? searchRef.current : listRef.current)?.focus({ preventScroll: true });
  }, [autoFocus, searchable]);

  useEffect(() => {
    if (active == null) {
      glide.update(null);
      return;
    }
    const row = rowRefs.current[active];
    if (row) {
      glide.update(row);
      row.scrollIntoView({ block: "nearest" });
    }
  }, [active, glide]);

  const pick = (index: number) => {
    const entry = entries[index];
    if (!entry || entry === "separator" || entry.disabled) return;
    onClose();
    entry.onSelect?.();
  };

  const move = (dir: 1 | -1) => {
    if (!selectable.length) return;
    const pos = selectable.findIndex(({ index }) => index === active);
    const next = pos < 0 ? (dir > 0 ? 0 : selectable.length - 1) : (pos + dir + selectable.length) % selectable.length;
    setActive(selectable[next].index);
  };

  return (
    <div
      ref={(el) => {
        listRef.current = el;
        glide.containerRef.current = el;
      }}
      className="cc-menu"
      role="menu"
      tabIndex={-1}
      onPointerLeave={() => setActive(null)}
      onKeyDown={(e) => {
        if (e.key === "ArrowDown") {
          e.preventDefault();
          move(1);
        } else if (e.key === "ArrowUp") {
          e.preventDefault();
          move(-1);
        } else if (e.key === "Enter" && active != null) {
          e.preventDefault();
          pick(active);
        }
      }}
    >
      <GlideWash glide={glide} />
      {searchable && (
        <div className="cc-menu__search">
          <input
            ref={searchRef}
            className="cc-field cc-mat-recessed"
            data-size="sm"
            placeholder={searchPlaceholder}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setActive(null);
            }}
          />
        </div>
      )}
      {visible.length === 0 && <div className="cc-menu__empty">{emptyText}</div>}
      {visible.map(({ entry, index }) =>
        entry === "separator" ? (
          <div key={`sep-${index}`} className="cc-menu__sep" />
        ) : (
          <div
            key={`${index}-${entry.title}`}
            ref={(el) => {
              rowRefs.current[index] = el;
            }}
            role="menuitemradio"
            aria-checked={entry.checked ?? false}
            aria-disabled={entry.disabled || undefined}
            className={`cc-menu__row${entry.destructive ? " cc-menu__row--destructive" : ""}`}
            onPointerEnter={() => !entry.disabled && setActive(index)}
            onPointerUp={() => pick(index)}
          >
            <span>{entry.title}</span>
            {entry.subtitle && <span className="cc-menu__sub">{entry.subtitle}</span>}
            {entry.checked && (
              <span className="cc-menu__check">
                <SFIcon name="checkmark" size={10} weight="bold" />
              </span>
            )}
          </div>
        ),
      )}
    </div>
  );
}

export interface SelectOption {
  title: string;
  subtitle?: string;
}

/**
 * CCSelect / CCCombobox trigger + popup.
 *  • chrome "elevated": the form look — a recessed well holding the value.
 *  • chrome "plain": the title-bar look — bare at rest, quiet wash on hover.
 *  • chrome "flat": InspectorMenuControl — chevron LEADING the title, no box.
 */
export function Select({
  options,
  selectedIndex,
  onSelect,
  placeholder = "Select…",
  size = "regular",
  chrome = "elevated",
  minTriggerWidth,
  searchable = false,
  overrideTitle,
  disabled,
  ariaLabel,
  width,
}: {
  options: readonly SelectOption[];
  selectedIndex: number | null;
  onSelect: (index: number) => void;
  placeholder?: string;
  size?: "sm" | "regular";
  chrome?: "elevated" | "plain" | "flat";
  minTriggerWidth?: number;
  searchable?: boolean;
  overrideTitle?: string;
  disabled?: boolean;
  ariaLabel?: string;
  width?: number | string;
}) {
  const triggerRef = useRef<HTMLButtonElement>(null);
  const [anchor, setAnchor] = useState<AnchorRect | null>(null);
  const hasValue = selectedIndex != null && selectedIndex >= 0 && selectedIndex < options.length;
  const label = overrideTitle ?? (hasValue ? options[selectedIndex!].title : placeholder);
  const chevronPt = chrome === "flat" ? 9 : size === "sm" ? 8 : 9;

  const entries: MenuEntry[] = options.map((o, i) => ({
    title: o.title,
    subtitle: o.subtitle,
    checked: i === selectedIndex,
    onSelect: () => i !== selectedIndex && onSelect(i),
  }));

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={anchor != null}
        aria-label={ariaLabel}
        className={`cc-select${chrome === "elevated" ? " cc-mat-recessed" : ""}`}
        data-size={size}
        data-chrome={chrome}
        data-open={anchor != null || undefined}
        data-empty={!hasValue && !overrideTitle ? true : undefined}
        style={{ minWidth: minTriggerWidth, width, opacity: disabled ? "var(--cc-disabled-alpha)" : undefined }}
        onPointerDown={(e) => {
          if (e.button !== 0 || disabled) return;
          e.preventDefault();
          // Measure NOW: React clears `currentTarget` after dispatch, and the
          // updater may run later (a pending update on the fiber defers it).
          const rect = rectOf(e.currentTarget);
          setAnchor((a) => (a ? null : rect));
        }}
        onKeyDown={(e) => {
          if ((e.key === "Enter" || e.key === " " || e.key === "ArrowDown") && !anchor) {
            e.preventDefault();
            setAnchor(rectOf(e.currentTarget));
          }
        }}
      >
        <span className="cc-select__label">{label}</span>
        <span className="cc-select__chev">
          <SFIcon name="chevron.up.chevron.down" size={chevronPt} weight="semibold" />
        </span>
      </button>
      {anchor && (
        <Floating
          anchor={anchor}
          edge="below"
          align={chrome === "flat" ? "end" : "start"}
          minWidth={Math.max(anchor.width, 180)}
          onDismiss={() => setAnchor(null)}
          ignore={triggerRef.current}
        >
          <MenuList entries={entries} searchable={searchable} onClose={() => setAnchor(null)} />
        </Floating>
      )}
    </>
  );
}

/** Context menu at a point (the timeline lanes' right-click menus). */
export function ContextMenu({
  at,
  entries,
  onDismiss,
  edge = "below",
}: {
  at: { x: number; y: number };
  entries: MenuEntry[];
  onDismiss: () => void;
  edge?: Edge;
}) {
  return (
    <Floating anchor={{ left: at.x, top: at.y, width: 0, height: 0 }} edge={edge} gap={2} onDismiss={onDismiss} role="menu">
      <MenuList entries={entries} onClose={onDismiss} />
    </Floating>
  );
}

/** Generic anchored popover (colour picker, toolbar pickers). */
export function Popover({
  anchor,
  onDismiss,
  children,
  edge = "below",
  align = "start",
  ignore,
}: {
  anchor: AnchorRect;
  onDismiss: () => void;
  children: ReactNode;
  edge?: Edge;
  align?: "start" | "center" | "end";
  ignore?: Element | null;
}) {
  return (
    <Floating anchor={anchor} edge={edge} align={align} onDismiss={onDismiss} ignore={ignore}>
      {children}
    </Floating>
  );
}
