/**
 * The Subtitles pane's generate / manage rows, read straight off the element
 * tree the (hook-free) pane returns — no DOM needed.
 *
 * Regression: Regenerate used to fall back to `onProjectChange({ subtitles:
 * [] })` + a generator that did not exist, deleting every cue.
 */
import { isValidElement, type ReactElement, type ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";

import { newProject } from "../../core/model";
import { InspectorButton } from "../kit";
import { GENERATE_CAPTION, SubtitlesPane } from "./SubtitlesPane";
import type { PaneActions, PaneProps } from "./types";

type AnyElement = ReactElement<Record<string, unknown>>;

/** Every element reachable from `node` (props, children, rows, rendered items). */
function elements(node: unknown, out: AnyElement[] = []): AnyElement[] {
  if (Array.isArray(node)) {
    for (const n of node) elements(n, out);
  } else if (isValidElement(node)) {
    const el = node as AnyElement;
    out.push(el);
    for (const [key, value] of Object.entries(el.props)) {
      if (key === "items" && Array.isArray(value)) {
        // PaneStack items ({ show, render }); other `items` props (Chips) are data.
        for (const item of value as { show?: boolean; render?(first: boolean): ReactNode }[]) {
          if (typeof item?.render === "function" && item.show !== false) elements(item.render(false), out);
        }
      } else if (key === "rows" && Array.isArray(value)) {
        for (const row of value as { show?: boolean; node: ReactNode }[]) if (row.show !== false) elements(row.node, out);
      } else elements(value, out);
    }
  }
  return out;
}

const text = (el: AnyElement) => String(el.props.children ?? "");

function pane(actions: Partial<PaneActions>, withCues = true) {
  const project = newProject({ duration: 10, videoURL: "recording.mov" });
  project.settings.showSubtitles = true;
  if (withCues) project.subtitles = [{ id: "A", startTime: 1, endTime: 2, text: "Hello", words: [] }];
  const onProjectChange = vi.fn();
  const props: PaneProps = { settings: project.settings, onSettingsChange: vi.fn(), project, onProjectChange, actions };
  const tree = elements(SubtitlesPane(props));
  const button = (label: string) => tree.find((el) => el.type === InspectorButton && text(el) === label);
  return { tree, onProjectChange, button };
}

describe("SubtitlesPane generate / manage", () => {
  it("Regenerate never deletes the cues itself", () => {
    const onGenerateSubtitles = vi.fn();
    const { button, onProjectChange } = pane({ onGenerateSubtitles });
    (button("Regenerate")!.props.onClick as () => void)();
    expect(onGenerateSubtitles).toHaveBeenCalledTimes(1);
    expect(onProjectChange).not.toHaveBeenCalled();

    const onRegenerateSubtitles = vi.fn();
    const withHandler = pane({ onGenerateSubtitles, onRegenerateSubtitles });
    (withHandler.button("Regenerate")!.props.onClick as () => void)();
    expect(onRegenerateSubtitles).toHaveBeenCalledTimes(1);
    expect(withHandler.onProjectChange).not.toHaveBeenCalled();

    // No generator at all: the button is inert, the cues stay.
    const inert = pane({});
    (inert.button("Regenerate")!.props.onClick as () => void)();
    expect(inert.onProjectChange).not.toHaveBeenCalled();
  });

  it("while transcribing: spinner, progress, Cancel — no Regenerate / Delete", () => {
    const onCancelSubtitles = vi.fn();
    const { tree, button } = pane({ onCancelSubtitles, subtitleStatus: { busy: true, progress: "Transcribing... 40%", error: null } });
    expect(tree.some((el) => el.props.className === "cc-spin")).toBe(true);
    expect(tree.some((el) => text(el) === "Transcribing... 40%")).toBe(true);
    (button("Cancel")!.props.onClick as () => void)();
    expect(onCancelSubtitles).toHaveBeenCalled();
    expect(button("Regenerate")).toBeUndefined();
    expect(button("Delete")).toBeUndefined();
  });

  it("shows Generate with the model-size copy, and errors in red", () => {
    const { tree } = pane({ subtitleStatus: { busy: false, error: "Audio extraction failed: No audio track found" } }, false);
    expect(tree.some((el) => text(el) === "Generate Subtitles")).toBe(true);
    expect(tree.some((el) => text(el) === GENERATE_CAPTION)).toBe(true);
    expect(GENERATE_CAPTION).toMatch(/^Auto-transcribes audio with Whisper AI\. The model downloads automatically on first use \(~\d+ MB\)\.$/);
    const error = tree.find((el) => el.props.className === "cc-pane-error");
    expect(text(error!)).toBe("Audio extraction failed: No audio track found");
  });
});
