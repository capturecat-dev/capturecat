/**
 * CCKit callout — the web twin of `Views/Shared/DesignKit/CCCallout.swift`
 * (shadcn's inline Alert): a raised MATTE panel (radius lg) with a leading
 * variant glyph, a semibold 13pt title and a 12pt muted description.
 *
 *   - Fill: the card with a whisper of the variant hue (opaque — translucent
 *     fills are never dressed); info stays plain card with the hairline
 *     border, the others take a tinted border.
 *   - Arrives with a fade while falling a few points into place (spring
 *     smooth), like `playEntrance()`.
 *   - Dismissible: × (ghost, sm) centred on the title line; dismissing
 *     COLLAPSES the panel — the bottom edge rises (glide, 0.3 s) while the
 *     surface fades (0.2 s) — then `onDismiss` fires.
 */
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

import { Button } from "./Button";
import { SFIcon } from "./icons";

export type CalloutVariant = "info" | "success" | "warning" | "destructive";

const SYMBOL: Record<CalloutVariant, string> = {
  info: "info.circle.fill",
  success: "checkmark.circle.fill",
  warning: "exclamationmark.triangle.fill",
  destructive: "exclamationmark.octagon.fill",
};

const TINT: Record<CalloutVariant, string> = {
  info: "var(--cc-primary)",
  success: "var(--cc-system-green, #30d158)",
  warning: "var(--cc-system-orange)",
  destructive: "var(--cc-destructive)",
};

export function Callout({
  title,
  message,
  variant = "info",
  dismissible = false,
  onDismiss,
  className,
  style,
  role = "status",
}: {
  title: ReactNode;
  message?: ReactNode;
  variant?: CalloutVariant;
  dismissible?: boolean;
  onDismiss?: () => void;
  className?: string;
  style?: CSSProperties;
  role?: "status" | "alert" | "note";
}) {
  const [leaving, setLeaving] = useState(false);
  const done = useRef(false);
  const onDismissRef = useRef(onDismiss);
  onDismissRef.current = onDismiss;

  useEffect(() => {
    if (!leaving) return;
    // The collapse runs 0.3 s at standard pace; finish even if transitionend never fires.
    const t = window.setTimeout(finish, 360);
    return () => window.clearTimeout(t);
  }, [leaving]);

  function finish() {
    if (done.current) return;
    done.current = true;
    onDismissRef.current?.();
  }

  return (
    <div
      className={`cc-callout${className ? ` ${className}` : ""}`}
      data-variant={variant}
      data-leaving={leaving || undefined}
      role={role}
      style={{ "--c-tint": TINT[variant], ...style } as CSSProperties}
      onTransitionEnd={(e) => {
        if (leaving && e.target === e.currentTarget && e.propertyName === "grid-template-rows") finish();
      }}
    >
      <div className="cc-callout__clip">
        <div className="cc-callout__surface cc-mat-matte">
          <SFIcon name={SYMBOL[variant]} size={14} weight="medium" className="cc-callout__icon" />
          <div className="cc-callout__text">
            <div className="cc-callout__title">{title}</div>
            {message != null && <div className="cc-callout__message">{message}</div>}
          </div>
          {dismissible && (
            <Button
              variant="ghost"
              size="sm"
              symbol="xmark"
              className="cc-callout__close"
              aria-label="Dismiss"
              onClick={() => setLeaving(true)}
            />
          )}
        </div>
      </div>
    </div>
  );
}
