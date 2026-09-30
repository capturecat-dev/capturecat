import { describe, expect, it } from "vitest";

import catalog from "./catalog.generated.json";
import { webmcpOriginTrialMeta } from "./originTrial";
import {
  DESKTOP_ONLY_TOOLS,
  WEB_TOOLS,
  findModelContext,
  registerEditorTools,
  webCatalog,
  type ModelContextToolDescriptor,
} from "./register";

function fakeContext() {
  const registered: ModelContextToolDescriptor[] = [];
  const signals: AbortSignal[] = [];
  return {
    registered,
    signals,
    registerTool(tool: ModelContextToolDescriptor, options?: { signal?: AbortSignal }) {
      registered.push(tool);
      if (options?.signal) signals.push(options.signal);
    },
  };
}

describe("WebMCP catalog", () => {
  it("partitions every desktop tool into web or desktop-only — nothing unaccounted", () => {
    const desktop = (catalog.tools as { name: string }[]).map((t) => t.name).sort();
    const split = [...WEB_TOOLS, ...DESKTOP_ONLY_TOOLS].sort();
    expect(split).toEqual(desktop);
  });

  it("makes id optional and drops export's filesystem path", () => {
    const tools = webCatalog();
    for (const tool of tools) expect(tool.inputSchema.required ?? []).not.toContain("id");
    const exportTool = tools.find((t) => t.name === "export_project")!;
    expect(exportTool.inputSchema.properties).not.toHaveProperty("output");
    expect(exportTool.inputSchema.required ?? []).not.toContain("output");
  });

  it("leads with the playbook tool", () => {
    expect(webCatalog()[0].name).toBe("get_editing_playbook");
  });
});

describe("registerEditorTools", () => {
  it("registers only tools with handlers, maps annotations, and unregisters via abort", async () => {
    const ctx = fakeContext();
    const unregister = registerEditorTools(
      {
        describe_project: async () => ({ id: "p1" }),
        cut_video: async () => ({ removedSeconds: 1 }),
      },
      ctx,
    );
    const names = ctx.registered.map((t) => t.name).sort();
    expect(names).toEqual(["cut_video", "describe_project", "get_editing_playbook"]);
    const describeTool = ctx.registered.find((t) => t.name === "describe_project")!;
    const cutTool = ctx.registered.find((t) => t.name === "cut_video")!;
    expect(describeTool.annotations).toEqual({ readOnlyHint: true, consequentialHint: false });
    expect(cutTool.annotations).toEqual({ readOnlyHint: false, consequentialHint: true });

    const signal = new AbortController().signal;
    expect(await describeTool.execute({}, { signal })).toBe('{"id":"p1"}');
    const playbook = ctx.registered.find((t) => t.name === "get_editing_playbook")!;
    expect(await playbook.execute({}, { signal })).toContain("TWO CLOCKS");

    expect(ctx.signals.every((s) => !s.aborted)).toBe(true);
    unregister();
    expect(ctx.signals.every((s) => s.aborted)).toBe(true);
  });

  it("turns handler failures into the desktop server's ERROR contract", async () => {
    const ctx = fakeContext();
    registerEditorTools({ set_style: async () => { throw new Error("key not whitelisted: foo"); } }, ctx);
    const tool = ctx.registered.find((t) => t.name === "set_style")!;
    expect(await tool.execute({}, { signal: new AbortController().signal }))
      .toBe("ERROR: key not whitelisted: foo");
  });

  it("is a no-op without WebMCP and prefers document.modelContext over navigator", () => {
    expect(registerEditorTools({}, null)).toBeTypeOf("function");
    const doc = fakeContext();
    const nav = fakeContext();
    expect(findModelContext({ document: { modelContext: doc }, navigator: { modelContext: nav } })).toBe(doc);
    expect(findModelContext({ document: {}, navigator: { modelContext: nav } })).toBe(nav);
    expect(findModelContext({ document: {}, navigator: {} })).toBeNull();
  });
});


describe("WebMCP origin trial", () => {
  it("emits the origin-trial meta only when a token is configured", () => {
    expect(webmcpOriginTrialMeta("")).toEqual([]);
    expect(webmcpOriginTrialMeta("tok123")).toEqual([{ httpEquiv: "origin-trial", content: "tok123" }]);
  });
});
