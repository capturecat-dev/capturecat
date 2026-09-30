/**
 * The inspector column (EditorInspectorViewController + InspectorColumnAppKit):
 * a card inset top 10 / trailing 14 with square bottom corners, a scrolling
 * pane host (18pt insets, 16pt bottom breathing room), a hairline and the
 * 84pt icon rail (72×56 buttons, 6pt apart, ONE gliding hover wash; the
 * selected tab sits on the elevated surface with the symbol's .fill).
 *
 * All panes stay mounted (their state survives tab switches, like the Mac's
 * stacked panes); only the selected one is visible.
 */
import { useEffect, useRef, type ReactNode } from "react";

import { GlideWash, SFIcon, useGlide } from "../kit";
import { INSPECTOR_TABS, type InspectorTabId } from "./types";

export function InspectorRail({
  selected,
  onSelect,
}: {
  selected: InspectorTabId;
  onSelect: (tab: InspectorTabId) => void;
}) {
  const glide = useGlide();
  return (
    <nav
      ref={glide.containerRef}
      className="cc-rail"
      role="tablist"
      aria-orientation="vertical"
      onPointerLeave={() => glide.update(null)}
    >
      <GlideWash glide={glide} />
      {INSPECTOR_TABS.map((tab) => {
        const isSelected = tab.id === selected;
        return (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={isSelected}
            className="cc-railbtn"
            onPointerEnter={(e) => glide.update(isSelected ? null : e.currentTarget)}
            onClick={() => {
              glide.update(null);
              onSelect(tab.id);
            }}
            onKeyDown={(e) => {
              const i = INSPECTOR_TABS.findIndex((t) => t.id === selected);
              if (e.key === "ArrowDown") onSelect(INSPECTOR_TABS[Math.min(INSPECTOR_TABS.length - 1, i + 1)].id);
              if (e.key === "ArrowUp") onSelect(INSPECTOR_TABS[Math.max(0, i - 1)].id);
            }}
          >
            <SFIcon name={isSelected && tab.filledIcon ? tab.filledIcon : tab.icon} size={21} weight="medium" />
            <span className="cc-railbtn__label">{tab.title}</span>
          </button>
        );
      })}
    </nav>
  );
}

export function Inspector({
  selected,
  onSelect,
  panes,
}: {
  selected: InspectorTabId;
  onSelect: (tab: InspectorTabId) => void;
  panes: Partial<Record<InspectorTabId, ReactNode>>;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    scrollRef.current?.scrollTo({ top: 0 });
  }, [selected]);
  return (
    <div className="cc-inspector">
      <div ref={scrollRef} className="cc-inspector__scroll">
        {INSPECTOR_TABS.map((tab) => (
          <div
            key={tab.id}
            className="cc-inspector__pane"
            role="tabpanel"
            aria-label={tab.title}
            hidden={tab.id !== selected}
          >
            {panes[tab.id] ?? null}
          </div>
        ))}
      </div>
      <div className="cc-inspector__hair" />
      <InspectorRail selected={selected} onSelect={onSelect} />
    </div>
  );
}

export function RevealTab({ onClick }: { onClick: () => void }) {
  return (
    <button type="button" className="cc-reveal" title="Show Inspector (⌥⌘I)" aria-label="Show Inspector" onClick={onClick}>
      <SFIcon name="chevron.left" size={9} weight="semibold" />
    </button>
  );
}
