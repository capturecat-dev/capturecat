import { describe, expect, it } from "vitest";

import {
  cleanSlugInput,
  contentChanged,
  emptyChangelogForm,
  formFromEntry,
  formProblem,
  inputFromForm,
  isDirty,
  isFutureDay,
  previewEntry,
  statusLine,
  togglePlatform,
  withTitle,
  type AdminChangelogEntry,
} from "./changelog-form";

const saved: AdminChangelogEntry = {
  id: "e1",
  slug: "agents-share-links",
  title: "Agents can publish share links",
  summary: "An agent asks first.",
  body: "## Details",
  category: "new",
  platforms: ["web", "agents"],
  version: "1.3.1",
  publishedAt: "2026-10-28T15:30:00.000Z",
  status: "published",
  createdAt: "2026-10-27T10:00:00.000Z",
  updatedAt: "2026-10-28T15:30:00.000Z",
  createdBy: "owner@test.local",
};

describe("changelog editor model", () => {
  it("suggests the slug from the title until the slug is typed", () => {
    let form = withTitle(emptyChangelogForm(), "Agents can publish share links!");
    expect(form.slug).toBe("agents-can-publish-share-links");
    form = { ...form, slug: cleanSlugInput("My Own_Slug!"), slugEdited: true };
    expect(form.slug).toBe("my-own-slug");
    expect(withTitle(form, "Another title").slug).toBe("my-own-slug");
    // A saved entry's slug is a URL: never re-suggested.
    expect(withTitle(formFromEntry(saved), "Renamed").slug).toBe("agents-share-links");
  });

  it("builds the API body: trimmed, one-line summary, canonical platform order, blank version = null", () => {
    const form = {
      ...emptyChangelogForm(),
      title: "  Title ",
      slug: "title",
      summary: " one\nline ",
      platforms: togglePlatform(togglePlatform(["agents"], "mac"), "web"),
      version: "  ",
    };
    expect(form.platforms).toEqual(["mac", "web", "agents"]);
    expect(inputFromForm(form)).toEqual({
      slug: "title",
      title: "Title",
      summary: "one line",
      body: "",
      category: "new",
      platforms: ["mac", "web", "agents"],
      version: null,
    });
    expect(togglePlatform(["mac", "web"], "mac")).toEqual(["web"]);
  });

  it("says what blocks a save", () => {
    const ok = { ...emptyChangelogForm(), title: "T", slug: "t", summary: "S" };
    expect(formProblem(ok)).toBeNull();
    expect(formProblem({ ...ok, title: " " })).toMatch(/title/);
    expect(formProblem({ ...ok, slug: "" })).toMatch(/slug/);
    expect(formProblem({ ...ok, slug: "bad-" })).toMatch(/slug/);
    expect(formProblem({ ...ok, summary: "" })).toMatch(/summary/);
    expect(formProblem({ ...ok, summary: "x".repeat(281) })).toMatch(/too long/);
  });

  it("knows what changed", () => {
    const form = formFromEntry(saved);
    expect(contentChanged(form, saved)).toBe(false);
    expect(isDirty(form, saved)).toBe(false);
    expect(form.date).toBe("2026-10-28");
    expect(isDirty({ ...form, date: "2026-10-01" }, saved)).toBe(true);
    expect(contentChanged({ ...form, date: "2026-10-01" }, saved)).toBe(false);
    expect(contentChanged({ ...form, body: "## Details\n\nMore" }, saved)).toBe(true);
    expect(isDirty(emptyChangelogForm(), null)).toBe(false);
    expect(isDirty({ ...emptyChangelogForm(), body: "x" }, null)).toBe(true);
  });

  it("status lines and scheduling", () => {
    expect(statusLine(saved)).toBe("Published 28 October 2026");
    expect(statusLine({ status: "scheduled", publishedAt: "2026-11-02T00:00:00.000Z" })).toBe("Scheduled for 2 November 2026");
    expect(statusLine({ status: "draft", publishedAt: null })).toBe("Draft");
    const now = new Date("2026-10-28T12:00:00Z");
    expect(isFutureDay("2026-10-29", now)).toBe(true);
    expect(isFutureDay("2026-10-28", now)).toBe(false);
    expect(isFutureDay("", now)).toBe(false);
  });

  it("previews the form as the page would print it", () => {
    const now = new Date("2026-10-28T12:00:00Z");
    expect(previewEntry(emptyChangelogForm(), null, now)).toMatchObject({ title: "Untitled entry", publishedAt: now.toISOString() });
    expect(previewEntry({ ...formFromEntry(saved), date: "2026-10-01" }, saved, now).publishedAt).toBe("2026-10-01T00:00:00.000Z");
    expect(previewEntry({ ...formFromEntry(saved), date: "" }, saved, now).publishedAt).toBe(saved.publishedAt);
  });
});
