/**
 * History → Compare: a client-side diff of two versions (or a version and
 * the current document), grouped by inspector tab plus Timeline and
 * Subtitles (state/history.ts `compareDocuments`). Clicking a timeline row
 * seeks there; a settings row brings its inspector tab forward underneath.
 */
import { formatClock, useHistory, type HistoryController } from "../../state/history";
import { GlideWash, useGlide } from "../kit";

export function ComparePanel({ history }: { history: HistoryController }) {
  const compare = useHistory(history, (s) => s.compare);
  const glide = useGlide();
  if (!compare) return null;
  const rows = compare.groups.reduce((n, g) => n + g.rows.length, 0);
  return (
    <div className="cc-history__page" data-history-compare="">
      <div className="cc-hcompare__sides cc-mat-recessed">
        <span title={compare.fromLabel}>{compare.fromLabel}</span>
        <span aria-hidden>→</span>
        <span title={compare.toLabel}>{compare.toLabel}</span>
      </div>
      {compare.loading && <div className="cc-hempty">Comparing…</div>}
      {compare.error && <div className="cc-hempty">{compare.error}</div>}
      {!compare.loading && !compare.error && rows === 0 && (
        <div className="cc-hempty">
          <div className="cc-hempty__title">No differences</div>
          <div>These versions are the same.</div>
        </div>
      )}
      <div ref={glide.containerRef} className="cc-hlist" onPointerLeave={() => glide.update(null)}>
        <GlideWash glide={glide} />
        {compare.groups.map((g) => (
          <section key={g.id} className="cc-hcompare__group" aria-label={g.title}>
            <div className="cc-hsection__title">{g.title}</div>
            {g.rows.map((row) => (
              <div
                key={row.id}
                className="cc-hcrow"
                role="button"
                tabIndex={0}
                data-row-id={row.id}
                title={row.sourceTime != null ? "Go there on the timeline" : row.tab ? "Show its inspector tab" : undefined}
                onPointerEnter={(e) => glide.update(e.currentTarget)}
                onClick={() => history.goTo(row)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    history.goTo(row);
                  }
                }}
              >
                <span>{row.text}</span>
                {row.sourceTime != null && <span className="cc-hcrow__at">{formatClock(row.sourceTime)}</span>}
              </div>
            ))}
          </section>
        ))}
      </div>
    </div>
  );
}
