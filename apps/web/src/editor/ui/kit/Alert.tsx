/**
 * CCAlert (Views/Shared/DesignKit/CCAlert.swift) — the house replacement
 * for `window.confirm` / NSAlert: a scrim fades over the editor and a raised
 * matte card springs in (Keynote scale-in), title (15 semibold) + muted
 * message (12, ≤ 296 wide) + a trailing button row.
 *
 *   const alerts = new AlertPresenter();          // one per page
 *   <AlertHost presenter={alerts} />              // inside <ThemeRoot>
 *   const i = await alerts.present({ title, message, buttons: [
 *     { title: "Generate", role: "primary" }, { title: "Cancel" } ] });
 *
 * Mac rules kept: buttons are listed default-first and laid out reversed
 * (the default sits trailing); the first button is primary unless it is
 * destructive; Return picks index 0, Escape the last button (NSAlert's
 * cancel slot) — both consumed so the editor's own shortcuts never see
 * them; the card is 340…440 wide (never wider than the window − 32, floor
 * 280) and sits 20 pt above centre.
 */
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";

import { Button } from "./Button";
import { animateCurve, animateSpring, curves } from "./motion";
import { useCCTheme } from "./theme";

export type AlertButtonRole = "primary" | "secondary" | "destructive";

export interface AlertButton {
  title: string;
  role?: AlertButtonRole;
}

export interface AlertSpec {
  title: string;
  message?: string;
  /** Default-first (index 0 = Return). Empty → a single "OK". */
  buttons?: AlertButton[];
}

interface PendingAlert {
  id: number;
  spec: AlertSpec;
  resolve: (index: number) => void;
}

/** Queue of alerts for one page; `present` resolves with the chosen index. */
export class AlertPresenter {
  private queue: PendingAlert[] = [];
  private listeners = new Set<() => void>();
  private nextId = 1;

  present(spec: AlertSpec): Promise<number> {
    return new Promise<number>((resolve) => {
      this.queue = [...this.queue, { id: this.nextId++, spec, resolve }];
      this.emit();
    });
  }

  /** The alert on screen (first in the queue). */
  current(): PendingAlert | null {
    return this.queue[0] ?? null;
  }

  finish(id: number, index: number): void {
    const hit = this.queue.find((a) => a.id === id);
    if (!hit) return;
    this.queue = this.queue.filter((a) => a.id !== id);
    hit.resolve(index);
    this.emit();
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private emit() {
    for (const l of this.listeners) l();
  }
}

export function AlertHost({ presenter }: { presenter: AlertPresenter }) {
  const current = useSyncExternalStore(presenter.subscribe, () => presenter.current(), () => null);
  if (!current) return null;
  return <AlertCard key={current.id} alert={current} onFinish={(i) => presenter.finish(current.id, i)} />;
}

function AlertCard({ alert, onFinish }: { alert: PendingAlert; onFinish: (index: number) => void }) {
  const { portal } = useCCTheme();
  const cardRef = useRef<HTMLDivElement>(null);
  const scrimRef = useRef<HTMLDivElement>(null);
  const [top, setTop] = useState<number | null>(null);
  const finishing = useRef(false);
  const buttons: AlertButton[] = alert.spec.buttons?.length ? alert.spec.buttons : [{ title: "OK", role: "primary" }];

  // Entrance: scrim + card fade on the glide curve while the card settles in.
  useLayoutEffect(() => {
    const card = cardRef.current;
    if (!card) return;
    setTop(Math.max(16, Math.round((window.innerHeight - card.offsetHeight) / 2 - 20)));
    card.style.transformOrigin = "50% 50%";
    animateSpring(card, [{ transform: "scale(0.96)" }, { transform: "scale(1)" }], "smooth");
    animateCurve(card, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
    if (scrimRef.current) animateCurve(scrimRef.current, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
  }, [portal]);

  const finish = (index: number) => {
    if (finishing.current) return;
    finishing.current = true;
    const card = cardRef.current;
    const scrim = scrimRef.current;
    if (!card || !scrim) return onFinish(index);
    animateSpring(card, [{ transform: "scale(1)" }, { transform: "scale(0.97)" }], "snappy");
    animateCurve(scrim, [{ opacity: 1 }, { opacity: 0 }], { duration: 0.16, curve: curves.glide });
    const a = animateCurve(card, [{ opacity: 1 }, { opacity: 0 }], { duration: 0.16, curve: curves.glide });
    if (!a) return onFinish(index);
    a.addEventListener("finish", () => onFinish(index), { once: true });
  };
  const finishRef = useRef(finish);
  finishRef.current = finish;

  // Return → the default button; Escape → the cancel slot. Capture phase +
  // stopPropagation: the editor's Esc (deselect) / Space (play) never fire.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        finishRef.current(buttons.length > 1 ? buttons.length - 1 : 0);
      } else if (e.key === "Enter") {
        e.preventDefault();
        e.stopPropagation();
        finishRef.current(0);
      } else if (!(e.metaKey || e.ctrlKey)) {
        // Modal: the editor underneath gets no plain keys.
        e.stopPropagation();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [buttons.length]);

  if (!portal) return null;
  return createPortal(
    <div className="cc-alert">
      <div ref={scrimRef} className="cc-alert__scrim" onPointerDown={(e) => e.preventDefault()} />
      <div
        ref={cardRef}
        className="cc-alert__card cc-mat-matte"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={`cc-alert-title-${alert.id}`}
        style={{ top: top ?? undefined, visibility: top === null ? "hidden" : undefined }}
      >
        <div id={`cc-alert-title-${alert.id}`} className="cc-alert__title">
          {alert.spec.title}
        </div>
        {alert.spec.message ? <div className="cc-alert__message">{alert.spec.message}</div> : null}
        <div className="cc-alert__buttons">
          {buttons
            .map((b, index) => ({ b, index }))
            .reverse()
            .map(({ b, index }) => {
              const role = b.role ?? "secondary";
              const variant = index === 0 && role === "secondary" ? "primary" : role;
              return (
                <Button key={index} variant={variant} onClick={() => finish(index)}>
                  {b.title}
                </Button>
              );
            })}
        </div>
      </div>
    </div>,
    portal,
  );
}
