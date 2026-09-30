/**
 * /editor — the cloud project picker. One stacked surface with hairline rows
 * (house rule for list pages: no card grids), in the editor's own kit.
 * Data: cloud projects (state/cloud.ts) plus — on the dev server only — this
 * Mac's local projects (state/projectSource.ts). Ids are the Mac's UUIDs.
 */
import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";

import { Button, SFIcon, ThemeRoot } from "../kit";
import { formatTimecode } from "../timeline/snap";
import { listEditorProjects, type EditorProjectSummary } from "../../state/projectSource";

function relative(iso: string | null): string {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  const mins = Math.round((Date.now() - then) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days} d ago`;
  return new Date(iso).toLocaleDateString();
}

/** `linkBase` (dev lab only) opens projects at `<linkBase>?id=<UUID>`
 *  instead of the guarded /app/editor/<UUID> route. */
export function ProjectPicker({ userName, linkBase }: { userName?: string; linkBase?: string }) {
  const [projects, setProjects] = useState<EditorProjectSummary[] | null>(null);
  useEffect(() => {
    let alive = true;
    void listEditorProjects().then((p) => alive && setProjects(p));
    return () => {
      alive = false;
    };
  }, []);

  return (
    <ThemeRoot>
      <div className="cc-picker-page">
        <header className="cc-picker-page__bar">
          <span className="cc-picker-page__brand">CaptureCat</span>
          <span className="cc-picker-page__crumb">Web Editor</span>
          <span style={{ flex: 1 }} />
          {userName && <span className="cc-caption">{userName}</span>}
          <Button variant="ghost" size="sm" symbol="square.grid.2x2" onClick={() => window.location.assign("/app")}>
            Library
          </Button>
        </header>
        <main className="cc-picker-page__main">
          <div className="cc-section__header" style={{ marginBottom: 12 }}>
            {import.meta.env.DEV ? "Projects (cloud + this Mac)" : "Recent cloud projects"}
          </div>
          <div className="cc-picker-list">
            {projects === null && <div className="cc-picker-empty">Loading…</div>}
            {projects?.length === 0 && (
              <div className="cc-picker-empty">
                <SFIcon name="icloud.and.arrow.up" size={22} weight="regular" />
                <div className="cc-gate__title">No cloud projects yet</div>
                <div className="cc-gate__body">
                  In the Mac app, open a capture and choose <b>Open in Web Editor</b>. It uploads the project and opens it here.
                </div>
              </div>
            )}
            {projects?.map((p) => {
              const body = (
                <>
                <span className="cc-picker-row__thumb" data-aspect={p.aspectRatio}>
                  {p.thumbnailUrl ? <img src={p.thumbnailUrl} alt="" /> : <SFIcon name="macwindow" size={16} weight="regular" />}
                </span>
                <span className="cc-picker-row__text">
                  <span className="cc-picker-row__name">{p.name}</span>
                  <span className="cc-picker-row__meta">
                    {p.duration > 0 ? `${formatTimecode(p.duration)} · ` : ""}
                    {p.aspectRatio} · edited {relative(p.updatedAt)} · {p.origin === "cloud" ? "Cloud" : "On this Mac"}
                  </span>
                </span>
                <SFIcon name="chevron.right" size={11} weight="semibold" className="cc-picker-row__chev" />
                </>
              );
              return linkBase ? (
                <a key={p.id} href={`${linkBase}?id=${encodeURIComponent(p.id)}`} className="cc-picker-row">
                  {body}
                </a>
              ) : (
                <Link key={p.id} to="/app/editor/$projectId" params={{ projectId: p.id }} className="cc-picker-row">
                  {body}
                </Link>
              );
            })}
          </div>
        </main>
      </div>
    </ThemeRoot>
  );
}
