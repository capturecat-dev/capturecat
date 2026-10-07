import { Fragment, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { Info, Lightbulb, Sparkles, TriangleAlert } from "lucide-react";

import { headingId, type DocBlock } from "@/lib/docs";
import { cn } from "@/lib/utils";

/**
 * Renders the docs content model (lib/docs/types.ts). Text goes through
 * `Inline`, which understands exactly **bold**, `code` and [label](href) —
 * never raw HTML, so content can't inject markup.
 */

const TOKEN = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)\s]+\))/g;

function DocLink({ href, children }: { href: string; children: ReactNode }) {
  const cls = "font-medium text-foreground underline decoration-white/25 underline-offset-4 transition-colors hover:decoration-white/70";
  if (href.startsWith("/docs/") || href === "/docs") {
    const [path, hash] = href.split("#");
    const splat = path.replace(/^\/docs\/?/, "");
    return splat ? (
      <Link to="/docs/$" params={{ _splat: splat }} hash={hash} className={cls}>
        {children}
      </Link>
    ) : (
      <Link to="/docs" className={cls}>
        {children}
      </Link>
    );
  }
  const external = /^https?:\/\//.test(href) && !href.startsWith("https://capturecat.so");
  return (
    <a href={href} className={cls} {...(external ? { target: "_blank", rel: "noopener noreferrer" } : {})}>
      {children}
    </a>
  );
}

export function Inline({ text }: { text: string }) {
  const parts = text.split(TOKEN);
  return (
    <>
      {parts.map((part, i) => {
        if (part.startsWith("**") && part.endsWith("**")) {
          return (
            <strong key={i} className="font-semibold text-foreground">
              {part.slice(2, -2)}
            </strong>
          );
        }
        if (part.startsWith("`") && part.endsWith("`") && part.length > 1) {
          return (
            <code key={i} className="rounded-md border border-white/10 bg-white/[0.06] px-1.5 py-0.5 font-mono text-[0.86em] text-foreground/90">
              {part.slice(1, -1)}
            </code>
          );
        }
        const link = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(part);
        if (link) {
          return (
            <DocLink key={i} href={link[2]}>
              {link[1]}
            </DocLink>
          );
        }
        return <Fragment key={i}>{part}</Fragment>;
      })}
    </>
  );
}

const CALLOUT = {
  note: { icon: Info, label: "Note", cls: "border-sky-300/20 bg-sky-300/[0.06]", iconCls: "text-sky-300" },
  tip: { icon: Lightbulb, label: "Tip", cls: "border-emerald-300/20 bg-emerald-300/[0.06]", iconCls: "text-emerald-300" },
  warning: { icon: TriangleAlert, label: "Warning", cls: "border-amber-300/25 bg-amber-300/[0.07]", iconCls: "text-amber-300" },
  pro: { icon: Sparkles, label: "Pro", cls: "border-violet-300/20 bg-violet-300/[0.07]", iconCls: "text-violet-300" },
} as const;

const glass = "relative overflow-hidden rounded-2xl border border-white/10 bg-white/[0.045] backdrop-blur-2xl";

function Block({ block }: { block: DocBlock }) {
  switch (block.type) {
    case "p":
      return (
        <p className="text-pretty text-[15.5px] leading-[1.75] text-muted-foreground">
          <Inline text={block.text} />
        </p>
      );
    case "h2":
      return (
        <h2 id={headingId(block)} className="group scroll-mt-24 pt-6 text-2xl font-semibold tracking-[-0.02em]">
          <a href={`#${headingId(block)}`} className="no-underline">
            {block.text}
            <span aria-hidden className="ml-2 text-white/0 transition-colors group-hover:text-white/30">#</span>
          </a>
        </h2>
      );
    case "h3":
      return (
        <h3 id={headingId(block)} className="scroll-mt-24 pt-2 text-lg font-medium tracking-[-0.01em]">
          {block.text}
        </h3>
      );
    case "list": {
      const Tag = block.ordered ? "ol" : "ul";
      return (
        <Tag
          className={cn(
            "space-y-2.5 pl-5 text-[15.5px] leading-[1.7] text-muted-foreground marker:text-white/30",
            block.ordered ? "list-decimal" : "list-disc"
          )}
        >
          {block.items.map((item) => (
            <li key={item} className="pl-1">
              <Inline text={item} />
            </li>
          ))}
        </Tag>
      );
    }
    case "steps":
      return (
        <ol className="space-y-3">
          {block.steps.map((step, i) => (
            <li key={step.title} className={cn(glass, "flex gap-4 p-5")}>
              <span
                aria-hidden
                className="flex size-7 shrink-0 items-center justify-center rounded-full border border-white/15 bg-white/[0.06] text-[13px] font-medium tabular-nums"
              >
                {i + 1}
              </span>
              <div className="min-w-0">
                <h3 className="font-medium tracking-[-0.01em]">
                  <Inline text={step.title} />
                </h3>
                <p className="mt-1.5 text-[14.5px] leading-relaxed text-muted-foreground">
                  <Inline text={step.text} />
                </p>
              </div>
            </li>
          ))}
        </ol>
      );
    case "code":
      return (
        <figure className="space-y-2">
          {block.caption && (
            <figcaption className="text-sm text-muted-foreground">
              <Inline text={block.caption} />
            </figcaption>
          )}
          <div className={cn(glass, "rounded-xl")}>
            {block.lang && (
              <div className="border-b border-white/8 px-4 py-2 font-mono text-[11px] uppercase tracking-[0.12em] text-muted-foreground">
                {block.lang}
              </div>
            )}
            <pre className="overflow-x-auto p-4 font-mono text-[13px] leading-relaxed text-foreground/90">
              <code>{block.code}</code>
            </pre>
          </div>
        </figure>
      );
    case "callout": {
      const c = CALLOUT[block.tone];
      return (
        <div className={cn("flex gap-3 rounded-2xl border p-4", c.cls)}>
          <c.icon className={cn("mt-0.5 size-4 shrink-0", c.iconCls)} />
          <p className="text-[14.5px] leading-relaxed text-foreground/85">
            <span className="font-semibold text-foreground">{block.title ?? c.label}. </span>
            <Inline text={block.text} />
          </p>
        </div>
      );
    }
    case "table":
      return (
        <div className={cn(glass, "overflow-x-auto rounded-xl")}>
          <table className="w-full min-w-[520px] text-left text-[14px]">
            <thead>
              <tr className="border-b border-white/10">
                {block.head.map((h) => (
                  <th key={h} className="px-4 py-3 font-medium text-foreground">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((row, i) => (
                <tr key={i} className="border-b border-white/6 last:border-0 align-top">
                  {row.map((cell, j) => (
                    <td key={j} className="px-4 py-3 leading-relaxed text-muted-foreground">
                      <Inline text={cell} />
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    case "shortcuts":
      return (
        <div className={cn(glass, "divide-y divide-white/6 rounded-xl")}>
          {block.rows.map(([keys, action]) => (
            <div key={keys + action} className="flex items-center justify-between gap-4 px-4 py-2.5 text-[14px]">
              <span className="text-muted-foreground">
                <Inline text={action} />
              </span>
              <kbd className="shrink-0 rounded-md border border-white/15 bg-white/[0.06] px-2 py-0.5 font-mono text-[12.5px] text-foreground">
                {keys}
              </kbd>
            </div>
          ))}
        </div>
      );
  }
}

export function DocBlocks({ blocks }: { blocks: DocBlock[] }) {
  return (
    <div className="space-y-5">
      {blocks.map((block, i) => (
        <Block key={i} block={block} />
      ))}
    </div>
  );
}
