/**
 * CCButton (Views/Shared/DesignKit/CCButton.swift) — shadcn-style variants in
 * the house skeuomorphic chrome, plus the timeline's IconKey
 * (TimelineToolbarButton) and CaptureCatButton's `.quiet` style.
 *
 * Press is a tint in place — the fill darkens on the glide curve; nothing
 * moves or scales. No rings.
 */
import type { ButtonHTMLAttributes, CSSProperties, ReactNode } from "react";

import { SFIcon, type SFWeight } from "./icons";

export type ButtonVariant = "primary" | "secondary" | "outline" | "ghost" | "link" | "destructive";
export type ButtonSize = "sm" | "regular" | "lg";

const symbolPt: Record<ButtonSize, number> = { sm: 10, regular: 11, lg: 13 };

export interface ButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "children"> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  radius?: "sm" | "md" | "lg" | "full";
  /** SF Symbol name (see icons.tsx). A symbol with no children = square icon button. */
  symbol?: string;
  symbolPlacement?: "leading" | "trailing";
  children?: ReactNode;
}

export function Button({
  variant = "secondary",
  size = "regular",
  radius = "md",
  symbol,
  symbolPlacement = "leading",
  children,
  className,
  type = "button",
  ...rest
}: ButtonProps) {
  const iconOnly = symbol != null && (children == null || children === "");
  const icon = symbol ? <SFIcon name={symbol} size={symbolPt[size]} weight="medium" /> : null;
  return (
    <button
      type={type}
      className={`cc-button${className ? ` ${className}` : ""}`}
      data-variant={variant}
      data-size={size}
      data-radius={radius}
      data-icon-only={iconOnly || undefined}
      {...rest}
    >
      {symbolPlacement === "leading" && icon}
      {!iconOnly && children != null && <span>{children}</span>}
      {symbolPlacement === "trailing" && icon}
    </button>
  );
}

/**
 * TimelineToolbarButton — 32×30 raised key. Every icon is its own key (no
 * grouping pills); keys stand on their under edge alone (no cast shadow —
 * packed keys would smear into each other).
 */
export function IconKey({
  symbol,
  pointSize = 14,
  weight = "semibold",
  tint,
  active = false,
  className,
  style,
  type = "button",
  ...rest
}: Omit<ButtonHTMLAttributes<HTMLButtonElement>, "children"> & {
  symbol: string;
  pointSize?: number;
  weight?: SFWeight;
  /** Symbol colour override (red for destructive, cyan for an armed tool). */
  tint?: string;
  active?: boolean;
}) {
  return (
    <button
      type={type}
      className={`cc-key cc-mat-raised cc-mat-noshadow cc-press${className ? ` ${className}` : ""}`}
      data-active={active || undefined}
      style={{ ...(tint ? ({ "--k-ink": tint } as CSSProperties) : null), ...style }}
      {...rest}
    >
      <SFIcon name={symbol} size={pointSize} weight={weight} />
    </button>
  );
}

/** CaptureCatButton `.quiet` — bare text/icon, secondary ink, hover wash. */
export function QuietButton({
  symbol,
  children,
  height = 20,
  paddingX,
  selected,
  className,
  style,
  type = "button",
  ...rest
}: Omit<ButtonHTMLAttributes<HTMLButtonElement>, "children"> & {
  symbol?: string;
  children?: ReactNode;
  height?: number;
  paddingX?: number;
  selected?: boolean;
}) {
  return (
    <button
      type={type}
      className={`cc-quiet${className ? ` ${className}` : ""}`}
      data-selected={selected || undefined}
      style={{ "--q-h": `${height}px`, ...(paddingX != null ? { "--q-px": `${paddingX}px` } : null), ...style } as CSSProperties}
      {...rest}
    >
      {symbol && (
        // CaptureCatButton pins its symbol in an 18×18 frame.
        <span className="cc-icon" style={{ width: 18, height: 18 }}>
          <SFIcon name={symbol} size={12} weight="semibold" />
        </span>
      )}
      {children}
    </button>
  );
}

/** InspectorButton — flat raised chip inside panes; destructive = red text. */
export function InspectorButton({
  children,
  destructive,
  className,
  type = "button",
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { destructive?: boolean }) {
  return (
    <button
      type={type}
      className={`cc-ibutton cc-mat-raised${className ? ` ${className}` : ""}`}
      data-destructive={destructive || undefined}
      {...rest}
    >
      {children}
    </button>
  );
}

/** 1×18 hairline in an 11pt slot — the toolbar cluster separator. */
export function ToolbarSeparator() {
  return <span className="cc-vsep" aria-hidden />;
}
