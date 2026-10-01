/**
 * The History pane (docs/project-history.md §1 Web): the top-bar History key
 * swaps the inspector column to this surface.
 *
 *   HistoryOverlay   the column page: header, then the version list, Compare
 *                    (ComparePanel) or Merge Review (MergeReview). Arrives
 *                    sliding in from the trailing edge on the house spring
 *                    while fading; leaves the same way back. Reduced motion:
 *                    it simply appears / disappears.
 *   HistoryNotices   the stage callouts — "Viewing Sep 28, 3:42 PM — Ana on
 *                    Web [Restore] [Back to current]" and "Merged 2 changes
 *                    from Ana (Web)".
 *   useProjectHistory  one HistoryController per open CLOUD project.
 *
 * Built from the editor kit only (Button, Callout, ContextMenu, TextField,
 * glide wash, CCMotion); state lives in state/history.ts + the store.
 */
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";

import { diff, formatChangeSummary, type Json } from "../../core/merge";
import type { EditorController } from "../../state/controller";
import type { ProjectVersion } from "../../state/cloud";
import {
  authorInitial,
  cloudHistoryApi,
  daySections,
  formatBytes,
  formatTime,
  HistoryController,
  mergedCalloutTitle,
  useHistory,
  versionAuthor,
  versionBadges,
  versionCaption,
  type HistoryApi,
  type HistoryState,
} from "../../state/history";
import type { ProjectMedia } from "../../state/projectMedia";
import type { LoadedEditorProject } from "../../state/projectSource";
import { useEditorStore, type EditorState, type EditorStore } from "../../state/store";
import {
  animateCurve,
  animateSpring,
  Button,
  Callout,
  ContextMenu,
  curves,
  durations,
  GlideWash,
  SFIcon,
  TextField,
  useGlide,
  type AlertPresenter,
  type MenuEntry,
} from "../kit";
import { ComparePanel } from "./ComparePanel";
import { MergeReview } from "./MergeReview";

// ── Controller per project ──────────────────────────────────────────────

/**
 * The page's HistoryController: cloud projects only (null for this Mac's
 * read-only dev projects). `api` overrides the routes (lab harness).
 */
export function useProjectHistory(opts: {
  store: EditorStore;
  controller: EditorController;
  loaded: LoadedEditorProject | null;
  alerts: AlertPresenter;
  api?: HistoryApi;
}): HistoryController | null {
  const { store, controller, loaded, alerts, api } = opts;
  const history = useMemo(() => {
    if (!loaded || loaded.origin !== "cloud") return null;
    return new HistoryController({
      store,
      api: api ?? cloudHistoryApi(loaded.id),
      isOwner: loaded.cloud?.access === "owner",
      media: loaded.media ?? null,
      confirm: (spec) => alerts.present(spec),
      seekSource: (t) => controller.seekToSource(t),
      revealTab: (tab) => store.setInspectorTab(tab),
    });
  }, [store, controller, loaded, alerts, api]);
  useEffect(() => {
    const media = loaded?.media;
    if (!history || !media) return () => history?.dispose();
    // An upload that hits the storage cap because history keeps removed
    // media frees up through the pane's confirmed Free up, then retries.
    media.freeUpHandler = () => history.freeUp("upload");
    return () => {
      if (media.freeUpHandler) media.freeUpHandler = null;
      history.dispose();
    };
  }, [history, loaded]);
  return history;
}

// ── The column page ─────────────────────────────────────────────────────

const selectOpen = (s: HistoryState) => s.open;

/** Mounted while open (and through its exit). */
export function HistoryOverlay({ history, store }: { history: HistoryController; store: EditorStore }) {
  const open = useHistory(history, selectOpen);
  const [mounted, setMounted] = useState(open);
  const ref = useRef<HTMLDivElement>(null);
  const first = useRef(true);
  if (open && !mounted) setMounted(true);

  useLayoutEffect(() => {
    const el = ref.current;
    if (first.current && !open) {
      first.current = false;
      return;
    }
    first.current = false;
    if (!el) return;
    el.getAnimations().forEach((a) => a.cancel());
    if (open) {
      // In from the trailing edge: spring smooth for the travel, glide for the fade.
      el.style.transform = "";
      el.style.opacity = "";
      animateSpring(el, [{ transform: "translateX(28px)" }, { transform: "translateX(0px)" }], "smooth");
      animateCurve(el, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
      el.dataset.motion = "in";
    } else {
      el.dataset.motion = "out";
      const a = animateCurve(el, [{ opacity: 1, transform: "translateX(0px)" }, { opacity: 0, transform: "translateX(20px)" }], {
        duration: 0.2,
        curve: curves.settle,
      });
      if (!a) setMounted(false);
      else a.addEventListener("finish", () => !history.getState().open && setMounted(false), { once: true });
    }
  }, [open, mounted, history]);

  if (!mounted) return null;
  return (
    <aside ref={ref} className="cc-history" aria-label="History" data-history-panel="">
      <HistoryPage history={history} store={store} />
    </aside>
  );
}

function HistoryPage({ history, store }: { history: HistoryController; store: EditorStore }) {
  const mode = useHistory(history, (s) => s.mode);
  const compareTitle = useHistory(history, (s) => (s.compare ? "Compare" : ""));
  const bodyRef = useRef<HTMLDivElement>(null);
  // Page swaps (list ⇄ compare ⇄ review) cross-fade like CCMotion.fadeSwap.
  const lastMode = useRef(mode);
  useLayoutEffect(() => {
    if (lastMode.current === mode) return;
    lastMode.current = mode;
    const el = bodyRef.current;
    if (el) {
      el.scrollTop = 0;
      animateCurve(el, [{ opacity: 0 }, { opacity: 1 }], { duration: durations.fadeSwap, curve: curves.glide });
    }
  }, [mode]);

  const back = mode === "compare";
  return (
    <>
      <header className="cc-history__head" data-back={back || undefined}>
        {back && <Button variant="ghost" size="sm" symbol="chevron.left" aria-label="Back to History" onClick={() => history.showList()} />}
        <span className="cc-history__title">{mode === "review" ? "Review Merge" : mode === "compare" ? compareTitle : "History"}</span>
        <Button variant="ghost" size="sm" symbol="xmark" aria-label="Close History" title="Close History" onClick={() => history.close()} />
      </header>
      <div ref={bodyRef} className="cc-history__body">
        {mode === "review" ? <MergeReview history={history} store={store} /> : mode === "compare" ? <ComparePanel history={history} /> : <VersionList history={history} store={store} />}
      </div>
      {mode === "list" && <HistoryFooter history={history} />}
    </>
  );
}

// ── Version list ────────────────────────────────────────────────────────

const selectList = (s: HistoryState) => s;

const SYNC_LINE: Record<EditorState["sync"], string> = {
  saved: "Saved",
  saving: "Saving…",
  offline: "Offline — will save when back online",
  conflict: "Changed elsewhere",
  review: "Needs review",
  local: "Not synced",
};

function VersionList({ history, store }: { history: HistoryController; store: EditorStore }) {
  const s = useHistory(history, selectList);
  const preview = useEditorStore(store, (e) => e.preview);
  const glide = useGlide();
  const [menu, setMenu] = useState<{ at: { x: number; y: number }; entries: MenuEntry[]; id: string } | null>(null);
  const sections = useMemo(() => daySections(s.versions), [s.versions]);

  if (s.status === "gated") return <Upsell />;
  if (s.status === "unavailable") {
    return (
      <div className="cc-hempty">
        <SFIcon name="clock.arrow.circlepath" size={20} weight="regular" />
        <div className="cc-hempty__title">History isn’t available yet</div>
        <div>This project’s versions will show here once the cloud keeps them.</div>
      </div>
    );
  }

  const openMenu = (v: ProjectVersion, at: { x: number; y: number }) => {
    const isHead = v.id === s.headVersionId;
    const entries: MenuEntry[] = [
      { title: preview?.versionId === v.id ? "Back to Current" : "Preview", onSelect: () => (preview?.versionId === v.id ? history.backToCurrent() : void history.preview(v.id)) },
      { title: v.label ? "Rename Version…" : "Name This Version…", onSelect: () => history.startNaming(v.id) },
      "separator",
      { title: "Compare with Current", onSelect: () => void history.compareWithCurrent(v.id) },
      { title: "Compare with…", onSelect: () => history.armCompare(v.id) },
      "separator",
      { title: "Restore", disabled: isHead, onSelect: () => void history.restore(v.id) },
    ];
    if (history.isOwner) entries.push({ title: "Delete", destructive: true, disabled: isHead, onSelect: () => void history.remove(v.id) });
    setMenu({ at, entries, id: v.id });
  };

  const armed = s.comparePick ? history.version(s.comparePick) : null;
  return (
    <div className="cc-history__page">
      {s.message && <Callout variant="warning" dismissible title={s.message} onDismiss={() => history.dismissMessage()} />}
      {armed && (
        <Callout
          variant="info"
          title="Pick a version to compare"
          message={
            <>
              Compared with {formatTime(armed.updatedAt)} · {versionAuthor(armed)}
              <span className="cc-hnotice__actions">
                <Button size="sm" onClick={() => history.cancelCompare()}>
                  Cancel
                </Button>
              </span>
            </>
          }
        />
      )}
      <div ref={glide.containerRef} className="cc-hlist" role="list" onPointerLeave={() => glide.update(null)}>
        <GlideWash glide={glide} />
        <CurrentRow store={store} selected={!preview} onSelect={() => preview && history.backToCurrent()} onHover={(el) => glide.update(el)} />
        {s.status === "loading" && s.versions.length === 0 && <Skeleton />}
        {s.status === "error" && (
          <div className="cc-hempty">
            <div className="cc-hempty__title">Couldn’t load History</div>
            <div>{s.error}</div>
            <Button size="sm" onClick={() => void history.refresh()}>
              Try Again
            </Button>
          </div>
        )}
        {s.status === "ready" && s.versions.length === 0 && (
          <div className="cc-hempty">
            <div>No saved versions yet — edits are kept here as you work.</div>
          </div>
        )}
        {sections.map((section) => (
          <div key={section.key} className="cc-hsection" role="group" aria-label={section.title}>
            <div className="cc-hsection__title">{section.title}</div>
            {section.versions.map((v) => (
              <VersionRow
                key={v.id}
                v={v}
                history={history}
                selected={preview?.versionId === v.id}
                armed={s.comparePick === v.id}
                busy={s.busy === v.id}
                naming={s.naming === v.id}
                menuOpen={menu?.id === v.id}
                onHover={(el) => glide.update(el)}
                onMenu={(at) => openMenu(v, at)}
              />
            ))}
          </div>
        ))}
      </div>
      {s.nextBefore && (
        <div className="cc-hmore">
          <Button size="sm" variant="ghost" disabled={s.loadingMore} onClick={() => void history.loadMore()}>
            {s.loadingMore ? "Loading…" : "Show Older Versions"}
          </Button>
        </div>
      )}
      {menu && <ContextMenu at={menu.at} entries={menu.entries} onDismiss={() => setMenu(null)} />}
    </div>
  );
}

/** The "Current" top row: the live project and its sync state (+ what's unsaved). */
function CurrentRow({ store, selected, onSelect, onHover }: { store: EditorStore; selected: boolean; onSelect: () => void; onHover: (el: HTMLElement | null) => void }) {
  const sync = useEditorStore(store, (e) => e.sync);
  const dirty = useEditorStore(store, (e) => e.dirty);
  const version = useEditorStore(store, (e) => e.version);
  const unsaved = useMemo(() => {
    if (!dirty) return null;
    try {
      // What the next save carries (saved → live), e.g. "Zoom added".
      return formatChangeSummary(diff(store.savedDocument() as Json, store.liveDocumentJSON() as Json), 2);
    } catch {
      return null;
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dirty, version, store]);
  return (
    <div
      className="cc-hrow"
      role="listitem"
      data-selected={selected || undefined}
      data-current=""
      onPointerEnter={(e) => onHover(selected ? null : e.currentTarget)}
      onClick={onSelect}
    >
      <span className="cc-havatar cc-mat-raised cc-mat-short" data-current="">
        <SFIcon name="checkmark" size={10} weight="bold" />
      </span>
      <div className="cc-hrow__main">
        <div className="cc-hrow__top">
          <span className="cc-hrow__time">Current</span>
          {(sync === "review" || sync === "conflict" || sync === "offline") && (
            <span className="cc-hbadge" data-tone="state">
              {SYNC_LINE[sync]}
            </span>
          )}
        </div>
        <div className="cc-hrow__caption">{unsaved ? `Unsaved: ${unsaved}` : SYNC_LINE[sync]}</div>
      </div>
      <span />
    </div>
  );
}

function VersionRow({
  v,
  history,
  selected,
  armed,
  busy,
  naming,
  menuOpen,
  onHover,
  onMenu,
}: {
  v: ProjectVersion;
  history: HistoryController;
  selected: boolean;
  armed: boolean;
  busy: boolean;
  naming: boolean;
  menuOpen: boolean;
  onHover: (el: HTMLElement | null) => void;
  onMenu: (at: { x: number; y: number }) => void;
}) {
  const badges = versionBadges(v);
  const [draft, setDraft] = useState(v.label ?? "");
  useEffect(() => {
    if (naming) setDraft(v.label ?? "");
  }, [naming, v.label]);
  const agent = v.source === "agent";
  return (
    <div
      className="cc-hrow"
      role="listitem"
      aria-label={`${formatTime(v.updatedAt)} ${versionAuthor(v)}${v.label ? ` — ${v.label}` : ""}`}
      data-version-id={v.id}
      data-selected={selected || undefined}
      data-armed={armed || undefined}
      data-busy={busy || undefined}
      onPointerEnter={(e) => onHover(selected ? null : e.currentTarget)}
      onClick={(e) => {
        if (naming || (e.target as HTMLElement).closest("button, input")) return;
        if (history.pick(v.id)) return;
        if (!selected) void history.preview(v.id);
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        onMenu({ x: e.clientX, y: e.clientY });
      }}
    >
      <span className="cc-havatar cc-mat-raised cc-mat-short" data-agent={agent || undefined} title={v.actorName ?? undefined}>
        {authorInitial(v)}
      </span>
      <div className="cc-hrow__main">
        {v.label && !naming && <span className="cc-hrow__label">{v.label}</span>}
        <div className="cc-hrow__top">
          <span className={v.label ? "cc-hrow__who" : "cc-hrow__time"}>{formatTime(v.updatedAt)}</span>
          <span className="cc-hrow__who">{v.actorName ?? "Someone"}</span>
          {badges.map((b) => (
            <span key={b.text} className="cc-hbadge" data-tone={b.tone} title={b.title}>
              {b.text}
            </span>
          ))}
          {v.label && (
            <span className="cc-hbadge" data-tone="named" title="Named versions are kept until deleted">
              <SFIcon name="bookmark.fill" size={7} weight="bold" />
              Named
            </span>
          )}
        </div>
        {naming ? (
          <div className="cc-hrow__name">
            <TextField
              size="sm"
              autoFocus
              placeholder="Name this version"
              aria-label="Version name"
              value={draft}
              maxLength={120}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                e.stopPropagation();
                if (e.key === "Enter") void history.commitName(v.id, draft);
                if (e.key === "Escape") history.cancelNaming();
              }}
              onBlur={() => history.cancelNaming()}
            />
          </div>
        ) : (
          <div className="cc-hrow__caption">{busy ? "Working…" : versionCaption(v)}</div>
        )}
      </div>
      <Button
        variant="ghost"
        size="sm"
        symbol="ellipsis"
        className="cc-hrow__more"
        aria-label="Version actions"
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        onClick={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          onMenu({ x: r.left, y: r.bottom });
        }}
      />
    </div>
  );
}

function Skeleton() {
  return (
    <div className="cc-hskeleton" aria-label="Loading versions">
      {[0, 1, 2].map((i) => (
        <div key={i} className="cc-hskeleton__row">
          <span className="cc-hskeleton__dot" />
          <span>
            <span className="cc-hskeleton__line" style={{ display: "block" }} />
            <span className="cc-hskeleton__line" style={{ display: "block" }} />
          </span>
        </div>
      ))}
    </div>
  );
}

/** Free plans: one line and a way to the plans — not a broken panel. */
function Upsell() {
  return (
    <div className="cc-hempty" data-history-upsell="">
      <SFIcon name="clock.arrow.circlepath" size={20} weight="regular" />
      <div className="cc-hempty__title">Version history is part of Pro</div>
      <div>Pro keeps 30 days of versions plus 25 you name — preview, compare and restore any of them.</div>
      <Button variant="primary" size="sm" onClick={() => window.open("/app/billing", "_blank", "noopener")}>
        See Plans
      </Button>
    </div>
  );
}

function HistoryFooter({ history }: { history: HistoryController }) {
  const pinned = useHistory(history, (s) => s.pinnedMediaBytes);
  const freeable = useHistory(history, (s) => s.freeableBytes);
  const retention = useHistory(history, (s) => s.retention);
  const status = useHistory(history, (s) => s.status);
  const access = useHistory(history, (s) => s.access);
  const named = useHistory(history, (s) => s.versions.filter((v) => v.label).length);
  const busy = useHistory(history, (s) => s.busy === "free-up");
  if (status !== "ready") return null;
  if (pinned > 0 && (access ?? (history.isOwner ? "owner" : "member")) === "owner") {
    return (
      <footer className="cc-history__foot" data-history-footer="">
        <span title={freeable < pinned ? "Named versions keep the rest" : undefined}>History keeps {formatBytes(pinned)} of removed media</span>
        {freeable > 0 && (
          <Button size="sm" disabled={busy} onClick={() => void history.freeUp()}>
            {busy ? "Freeing…" : `Free Up ${formatBytes(freeable)}`}
          </Button>
        )}
      </footer>
    );
  }
  if (!retention) return null;
  return (
    <footer className="cc-history__foot">
      <span>
        Kept {retention.days} days · {retention.namedCount ?? named} of {retention.maxNamed} named
      </span>
    </footer>
  );
}

// ── Stage callouts ──────────────────────────────────────────────────────

/** Preview + merged callouts for the stage's notice slot (null when neither shows). */
export function HistoryNotices({
  history,
  store,
  media,
  extra,
}: {
  history: HistoryController | null;
  store: EditorStore;
  /** The project's media: an upload history's storage blocks gets the Free up callout. */
  media?: ProjectMedia | null;
  extra?: ReactNode;
}) {
  const preview = useEditorStore(store, (s) => s.preview);
  const block = useMediaHistoryBlock(media);
  const [freeing, setFreeing] = useState(false);
  const notice = useEditorStore(store, (s) => s.mergeNotice);
  const busy = useHistoryOrNull(history, (s) => s.busy);
  const mergedFrom = useHistoryOrNull(history, (s) => s.mergedFrom);

  // The merged callout steps aside on its own after a while.
  useEffect(() => {
    if (!notice) return;
    const t = window.setTimeout(() => store.dismissMergeNotice(), 9000);
    return () => window.clearTimeout(t);
  }, [notice, store]);

  const who = notice && mergedFrom?.noticeId === notice.id ? mergedFrom.who : null;
  if (!preview && !notice && !extra && !block) return null;
  return (
    <div className="cc-hnotices">
      {preview && history && (
        <Callout
          key={`preview-${preview.versionId}`}
          variant="info"
          title={`Viewing ${preview.title}`}
          message={
            <>
              {preview.missingPaths?.length
                ? `Read-only. ${preview.missingPaths.length === 1 ? "1 file" : `${preview.missingPaths.length} files`} from this version ${preview.missingPaths.length === 1 ? "is" : "are"} no longer stored (${preview.missingPaths.slice(0, 2).join(", ")}${preview.missingPaths.length > 2 ? "…" : ""}).`
                : "Read-only — edits are off while you look."}
              <span className="cc-hnotice__actions">
                <Button size="sm" variant="primary" disabled={busy === preview.versionId} onClick={() => void history.restore(preview.versionId)}>
                  Restore
                </Button>
                <Button size="sm" onClick={() => history.backToCurrent()}>
                  Back to Current
                </Button>
              </span>
            </>
          }
        />
      )}
      {notice && (
        <Callout
          key={`merged-${notice.id}`}
          variant="success"
          dismissible
          title={mergedCalloutTitle(notice.count, who)}
          message={
            notice.autoResolved > 0
              ? `${notice.autoResolved} edit${notice.autoResolved === 1 ? "" : "s"} to the same setting went to the most recent change. Both versions are in History.`
              : "Both versions are in History."
          }
          onDismiss={() => store.dismissMergeNotice()}
        />
      )}
      {block && (
        <Callout
          key="history-storage"
          variant="warning"
          title="This upload doesn’t fit your storage"
          message={
            <>
              {block.message}
              {media?.canFreeUpHistory && (
                <span className="cc-hnotice__actions">
                  <Button
                    size="sm"
                    variant="primary"
                    disabled={freeing}
                    data-history-free-up=""
                    onClick={() => {
                      setFreeing(true);
                      void media.requestFreeUp().finally(() => setFreeing(false));
                    }}
                  >
                    {freeing ? "Freeing Up…" : "Free Up History"}
                  </Button>
                </span>
              )}
            </>
          }
        />
      )}
      {extra}
    </div>
  );
}

/** The upload history's storage is blocking, live. */
function useMediaHistoryBlock(media: ProjectMedia | null | undefined) {
  const [, force] = useState(0);
  useEffect(() => media?.subscribe(() => force((n) => n + 1)), [media]);
  return media?.historyBlock ?? null;
}

const noop = () => () => {};
function useHistoryOrNull<T>(history: HistoryController | null, selector: (s: HistoryState) => T): T | null {
  // Hooks can't be conditional: subscribe to nothing when there's no controller.
  const subscribe = history ? history.subscribe : noop;
  const [, force] = useState(0);
  useEffect(() => subscribe(() => force((n) => n + 1)), [subscribe]);
  return history ? selector(history.getState()) : null;
}
