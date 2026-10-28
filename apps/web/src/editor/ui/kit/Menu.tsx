/**
 * Menu list, Select/Combobox (CCCombobox + CCSelect + InspectorMenuControl)
 * and ContextMenu — the 2026 menu spec, shared with the Mac's CCMenu.
 *
 * One list surface everywhere: a floating popover card (radius lg = 14, a
 * 0.5px hairline, a soft wide shadow, 6px padding) whose WIDTH FITS ITS
 * CONTENT (min 220, max 380): titles never truncate — the menu widens —
 * and descriptions wrap to at most two lines (the list widens until they
 * do). Height grows; it scrolls only past the viewport.
 *
 *  • Simple rows: 30px — kit icon 16 (muted), 13px title, a faint
 *    right-aligned shortcut in a key cap, the check far right.
 *  • Rich rows (title + description — the toolbar pickers): the icon sits in
 *    a 30×30 well tile that takes the accent (white glyph) on hover; 13px
 *    semibold title, 11.5px muted description ≤ 2 lines; min height 46.
 *  • Sections: a sentence-case header and a hairline between groups; a
 *    disabled group carries ONE caption saying why, its rows dimmed and not
 *    hoverable.
 *  • Motion: rows stagger in (fade + 6px rise, 18ms apart, first 8 rows);
 *    ONE wash glides between rows (transform), following pointer AND
 *    keyboard; picking pulses the wash once while the panel fades out
 *    (Floating's ghost exit). Reduced motion: fades only.
 */
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";

import { ccKitName, CCIcon } from "./ccIcon";
import { Floating, GlideWash, markPicked, rectOf, useGlide, type AnchorRect, type Edge } from "./Floating";
import { SFIcon } from "./icons";

export interface MenuItem {
  title: string;
  /** Trailing faint text (a value, a count). */
  subtitle?: string;
  /** A second line — makes the row a RICH row (icon tile + wrapped description). */
  description?: string;
  /** Kit icon name (or an SF alias the kit draws). */
  icon?: string;
  /** Key equivalent shown in a key cap, e.g. "⌘B" or "⌫". */
  shortcut?: string;
  checked?: boolean;
  disabled?: boolean;
  destructive?: boolean;
  onSelect?: () => void;
}
/** A group header. Rows after it (until the next section) belong to it. */
export interface MenuSection {
  section: string;
  /** One line under the header — say WHY a disabled group is disabled. */
  caption?: string;
  /** Dims the header and disables every row of the group. */
  disabled?: boolean;
}
export type MenuEntry = MenuItem | MenuSection | "separator";

const isSection = (e: MenuEntry): e is MenuSection => typeof e === "object" && "section" in e;
const isItem = (e: MenuEntry): e is MenuItem => typeof e === "object" && !("section" in e);

/** Rows that stagger in; later rows arrive with the last of them. */
const STAGGER_ROWS = 8;
const MIN_WIDTH = 220;
const MAX_WIDTH = 380;

/** A kit glyph at `px` CSS px (SF fallback for names the kit does not draw yet). */
export function MenuIcon({ name, px, weight = "regular" }: { name: string; px: number; weight?: "regular" | "medium" | "semibold" }) {
  return ccKitName(name) ? <CCIcon name={name} size={px} weight={weight} /> : <SFIcon name={name} size={px / 1.2} weight={weight} />;
}

type Row =
  | { kind: "item"; entry: MenuItem; index: number; disabled: boolean; order: number }
  | { kind: "section"; entry: MenuSection; index: number; first: boolean; order: number }
  | { kind: "separator"; index: number; order: number };

export function MenuList({
  entries,
  onClose,
  searchable = false,
  searchPlaceholder = "Search…",
  emptyText = "No results",
  autoFocus = true,
  role = "menu",
  minWidth,
  ariaLabel,
}: {
  entries: MenuEntry[];
  onClose: () => void;
  searchable?: boolean;
  searchPlaceholder?: string;
  emptyText?: string;
  autoFocus?: boolean;
  /** "listbox" for Select popups (rows become options). */
  role?: "menu" | "listbox";
  /** e.g. the Select trigger's width; the 220 floor still applies. */
  minWidth?: number;
  ariaLabel?: string;
}) {
  const glide = useGlide({ measure: "layout" });
  const baseId = useId();
  const [query, setQuery] = useState("");
  const [active, setActive] = useState<number | null>(null);
  const rowRefs = useRef<(HTMLDivElement | null)[]>([]);
  const listRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const picked = useRef(false);
  const typeahead = useRef({ text: "", at: 0 });

  // Filter, then lay out groups: a section's `disabled` flows to its rows;
  // separators/headers never lead, trail or double up.
  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    const out: Row[] = [];
    let groupDisabled = false;
    let pendingSection: { entry: MenuSection; index: number } | null = null;
    let pendingSep = false;
    let order = 0;
    entries.forEach((entry, index) => {
      if (entry === "separator") {
        pendingSep = out.length > 0;
        return;
      }
      if (isSection(entry)) {
        groupDisabled = !!entry.disabled;
        pendingSection = { entry, index };
        pendingSep = false;
        return;
      }
      if (q && !entry.title.toLowerCase().includes(q) && !entry.description?.toLowerCase().includes(q) && !entry.subtitle?.toLowerCase().includes(q)) return;
      if (pendingSection) {
        out.push({ kind: "section", entry: pendingSection.entry, index: pendingSection.index, first: out.length === 0, order: order++ });
        pendingSection = null;
        pendingSep = false;
      } else if (pendingSep) {
        out.push({ kind: "separator", index, order: order++ });
        pendingSep = false;
      }
      out.push({ kind: "item", entry, index, disabled: groupDisabled || !!entry.disabled, order: order++ });
    });
    return out;
  }, [entries, query]);

  const selectable = rows.filter((r): r is Extract<Row, { kind: "item" }> => r.kind === "item" && !r.disabled);
  const rich = rows.some((r) => r.kind === "item" && !!r.entry.description);
  const hasIcons = rows.some((r) => r.kind === "item" && !r.entry.description && !!r.entry.icon);
  const hasChecks = rows.some((r) => r.kind === "item" && r.entry.checked !== undefined);

  useEffect(() => {
    if (!autoFocus) return;
    const target = () => (searchable ? searchRef.current : listRef.current);
    target()?.focus({ preventScroll: true });
    // A right-click opens us during pointerdown; the press's default action
    // then focuses whatever was under it (the timeline) — take focus back.
    const raf = requestAnimationFrame(() => {
      const list = listRef.current;
      if (list && !list.contains(document.activeElement)) target()?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(raf);
  }, [autoFocus, searchable]);

  useEffect(() => {
    const wash = glide.washRef.current;
    if (active == null) {
      glide.update(null);
      return;
    }
    const row = rowRefs.current[active];
    if (row) {
      if (wash) wash.dataset.tone = row.dataset.destructive ? "destructive" : "";
      glide.update(row);
      row.scrollIntoView({ block: "nearest" });
    }
  }, [active, glide]);

  // Fit: the list is max-content clamped to [220, 380]; a description longer
  // than the cap wraps — widen until each wraps to at most two lines (before
  // paint, and before Floating measures us).
  useLayoutEffect(() => {
    const el = listRef.current;
    if (!el) return;
    el.style.width = "";
    const descs = [...el.querySelectorAll<HTMLElement>(".cc-menu__desc")];
    if (!descs.length) return;
    el.dataset.measuring = "true";
    const over = () =>
      descs.some((d) => {
        const lh = parseFloat(getComputedStyle(d).lineHeight) || 15;
        return d.scrollHeight > lh * 2 + 1;
      });
    let w = el.getBoundingClientRect().width;
    for (let i = 0; i < 40 && w < MAX_WIDTH && over(); i++) {
      w = Math.min(MAX_WIDTH, Math.ceil(w) + 8);
      el.style.width = `${w}px`;
    }
    delete el.dataset.measuring;
  }, [rows]);

  // Viewport-capped lists scroll: fade the edge(s) that hide more rows.
  const syncScrollEdges = () => {
    const el = listRef.current;
    if (!el) return;
    const up = el.scrollTop > 1;
    const down = el.scrollTop + el.clientHeight < el.scrollHeight - 1;
    const v = [up && "up", down && "down"].filter(Boolean).join(" ");
    if ((el.dataset.scroll ?? "") !== v) {
      if (v) el.dataset.scroll = v;
      else delete el.dataset.scroll;
    }
  };
  useEffect(() => {
    // After Floating has capped our height (its layout effect runs after ours).
    const raf = requestAnimationFrame(syncScrollEdges);
    return () => cancelAnimationFrame(raf);
  });

  const pick = (index: number) => {
    const entry = entries[index];
    if (picked.current || !entry || !isItem(entry)) return;
    const row = rows.find((r) => r.kind === "item" && r.index === index);
    if (!row || (row.kind === "item" && row.disabled)) return;
    picked.current = true;
    // The wash sits on the chosen row; the ghost exit pulses it once.
    setActive(index);
    const rowEl = rowRefs.current[index];
    if (rowEl) {
      const wash = glide.washRef.current;
      if (wash) wash.dataset.tone = rowEl.dataset.destructive ? "destructive" : "";
      glide.update(rowEl);
    }
    markPicked(listRef.current);
    onClose();
    entry.onSelect?.();
  };

  const move = (to: "next" | "prev" | "first" | "last") => {
    if (!selectable.length) return;
    const pos = selectable.findIndex((r) => r.index === active);
    let next: number;
    if (to === "first") next = 0;
    else if (to === "last") next = selectable.length - 1;
    else if (pos < 0) next = to === "next" ? 0 : selectable.length - 1;
    else next = (pos + (to === "next" ? 1 : -1) + selectable.length) % selectable.length;
    setActive(selectable[next].index);
  };

  const rowId = (index: number) => `${baseId}-r${index}`;
  const itemRole = role === "listbox" ? "option" : undefined;

  return (
    <div
      ref={(el) => {
        listRef.current = el;
        glide.containerRef.current = el;
      }}
      id={baseId}
      className="cc-menu"
      role={role}
      aria-label={ariaLabel}
      aria-activedescendant={active != null ? rowId(active) : undefined}
      tabIndex={-1}
      data-rich={rich || undefined}
      style={minWidth ? { minWidth: Math.max(MIN_WIDTH, Math.ceil(minWidth)) } : undefined}
      onPointerLeave={() => setActive(null)}
      onScroll={syncScrollEdges}
      onKeyDown={(e) => {
        if (e.key === "ArrowDown") {
          e.preventDefault();
          move("next");
        } else if (e.key === "ArrowUp") {
          e.preventDefault();
          move("prev");
        } else if (e.key === "Home" || e.key === "PageUp") {
          e.preventDefault();
          move("first");
        } else if (e.key === "End" || e.key === "PageDown") {
          e.preventDefault();
          move("last");
        } else if ((e.key === "Enter" || (e.key === " " && !searchable)) && active != null) {
          e.preventDefault();
          pick(active);
        } else if (e.key === "Tab") {
          e.preventDefault();
          onClose();
        } else if (!searchable && e.key.length === 1 && /\S/.test(e.key) && !e.metaKey && !e.ctrlKey && !e.altKey) {
          // Type-ahead: jump to the next row starting with what was typed.
          const now = performance.now();
          const ta = typeahead.current;
          ta.text = now - ta.at > 700 ? e.key.toLowerCase() : ta.text + e.key.toLowerCase();
          ta.at = now;
          const pos = selectable.findIndex((r) => r.index === active);
          const ordered = [...selectable.slice(pos + 1), ...selectable.slice(0, pos + 1)];
          const hit = ordered.find((r) => r.entry.title.trim().toLowerCase().startsWith(ta.text));
          if (hit) setActive(hit.index);
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
            role="searchbox"
            aria-controls={baseId}
            onChange={(e) => {
              setQuery(e.target.value);
              setActive(null);
            }}
          />
        </div>
      )}
      {rows.length === 0 && <div className="cc-menu__empty">{emptyText}</div>}
      {rows.map((row) => {
        const stagger = { ["--i" as string]: Math.min(row.order, STAGGER_ROWS) };
        if (row.kind === "separator") {
          return <div key={`sep-${row.index}`} className="cc-menu__sep" role="separator" style={stagger} />;
        }
        if (row.kind === "section") {
          const { entry } = row;
          return (
            <div
              key={`sec-${row.index}`}
              className="cc-menu__section"
              data-first={row.first || undefined}
              data-disabled={entry.disabled || undefined}
              role="presentation"
              style={stagger}
            >
              <div className="cc-menu__header">{entry.section}</div>
              {entry.caption ? (
                <div className="cc-menu__caption">
                  <MenuIcon name="info-fill" px={12} />
                  <span>{entry.caption}</span>
                </div>
              ) : null}
            </div>
          );
        }
        const { entry, index, disabled } = row;
        const isRich = !!entry.description;
        return (
          <div
            key={`${index}-${entry.title}`}
            id={rowId(index)}
            ref={(el) => {
              rowRefs.current[index] = el;
            }}
            role={itemRole ?? (entry.checked !== undefined ? "menuitemradio" : "menuitem")}
            aria-checked={itemRole ? undefined : entry.checked !== undefined ? entry.checked : undefined}
            aria-selected={itemRole ? !!entry.checked : undefined}
            aria-disabled={disabled || undefined}
            className="cc-menu__row"
            data-rich={isRich || undefined}
            data-active={active === index || undefined}
            data-destructive={entry.destructive || undefined}
            style={stagger}
            onPointerEnter={() => setActive(disabled ? null : index)}
            onPointerUp={(e) => {
              if (e.button === 0 || e.button === 2) pick(index);
            }}
          >
            {isRich ? (
              <span className="cc-menu__tile" aria-hidden>
                {entry.icon ? <MenuIcon name={entry.icon} px={15} weight="medium" /> : null}
              </span>
            ) : entry.icon ? (
              <span className="cc-menu__icon" aria-hidden>
                <MenuIcon name={entry.icon} px={16} />
              </span>
            ) : hasIcons ? (
              <span className="cc-menu__icon" aria-hidden />
            ) : null}
            <span className="cc-menu__text">
              <span className="cc-menu__title">{entry.title}</span>
              {isRich ? <span className="cc-menu__desc">{entry.description}</span> : null}
            </span>
            {entry.subtitle ? <span className="cc-menu__sub">{entry.subtitle}</span> : null}
            {entry.shortcut ? <kbd className="cc-menu__kbd">{entry.shortcut}</kbd> : null}
            {entry.checked ? (
              <span className="cc-menu__check" aria-hidden>
                <MenuIcon name="check" px={14} weight="semibold" />
              </span>
            ) : hasChecks ? (
              <span className="cc-menu__check" aria-hidden />
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

export interface SelectOption {
  title: string;
  subtitle?: string;
  icon?: string;
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
    icon: o.icon,
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
          onDismiss={() => {
            setAnchor(null);
            triggerRef.current?.focus({ preventScroll: true });
          }}
          ignore={triggerRef.current}
        >
          <MenuList
            entries={entries}
            searchable={searchable}
            role="listbox"
            ariaLabel={ariaLabel}
            minWidth={anchor.width}
            onClose={() => {
              setAnchor(null);
              triggerRef.current?.focus({ preventScroll: true });
            }}
          />
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
  ariaLabel,
}: {
  at: { x: number; y: number };
  entries: MenuEntry[];
  onDismiss: () => void;
  edge?: Edge;
  ariaLabel?: string;
}) {
  return (
    <Floating anchor={{ left: at.x, top: at.y, width: 0, height: 0 }} edge={edge} gap={2} onDismiss={onDismiss}>
      <MenuList entries={entries} onClose={onDismiss} ariaLabel={ariaLabel} />
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
