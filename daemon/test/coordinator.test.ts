import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { ClaudeCodeSession } from "../src/agents/claudeCode.ts";
import type { Classification } from "../src/agents/quick.ts";
import { findMention, stripMention } from "../src/coordinator.ts";
import { INBOX_ID, glob, normalizeURL, ruleForURL, urlMatches } from "../src/projects.ts";
import { parseContext } from "../src/protocol.ts";
import { bundle, world } from "./fixtures.ts";

const adapter = { name: "fake", startSession: ({ cwd }: { cwd: string }) => new ClaudeCodeSession(cwd) };
const ctx = (over: Record<string, unknown> = {}) => parseContext(bundle({ selection: undefined, url: undefined, ...over }));

function repo() {
  const root = mkdtempSync(join(tmpdir(), "code-"));
  const shop = join(root, "shop");
  mkdirSync(join(shop, ".git"), { recursive: true });
  mkdirSync(join(shop, "app", "models"), { recursive: true });
  writeFileSync(join(shop, "app", "models", "order.rb"), "");
  return shop;
}

const classifier = (r: Classification | undefined) => ({ calls: 0, async classify() { this.calls++; return r; } });

describe("routing steps", () => {
  test("1. an @mention or a picked project wins", async () => {
    const w = world(adapter);
    const shop = w.registry.save({ name: "shop", paths: ["/tmp/shop"] });
    const d = await w.coordinator.route({ id: "1", text: "@shop why is this failing?", context: ctx() });
    expect(d).toMatchObject({ step: "explicit", mention: "shop" });
    expect(d.project.id).toBe(shop.id);
    const picked = await w.coordinator.route({ id: "2", text: "anything", context: ctx(), project: shop.id });
    expect(picked.step).toBe("explicit");
    // An unknown @name, or an email address, doesn't count.
    expect((await w.coordinator.route({ id: "3", text: "mail kirby@shop.com", context: ctx() })).step).toBe("fallback");
    expect((await w.coordinator.route({ id: "4", text: "@nope hi", context: ctx() })).step).toBe("fallback");
  });

  test("2. a file in a registered folder routes there; an unregistered repo becomes a project", async () => {
    const w = world(adapter);
    const shop = repo();
    const d = await w.coordinator.route({ id: "1", text: "why?", context: ctx({ filePath: join(shop, "app", "models", "order.rb") }) });
    expect(d.step).toBe("path");
    expect(d.project.name).toBe("shop");
    expect(d.project.paths).toEqual([shop]);
    const again = await w.coordinator.route({ id: "2", text: "and?", context: ctx({ cwd: join(shop, "app") }) });
    expect(again.project.id).toBe(d.project.id);
    expect(w.registry.list()).toHaveLength(2); // Inbox and shop
  });

  test("2. the deepest registered folder wins", async () => {
    const w = world(adapter);
    const shop = repo();
    w.registry.save({ name: "shop", paths: [shop] });
    const models = w.registry.save({ name: "models", paths: [join(shop, "app", "models")] });
    const d = await w.coordinator.route({ id: "1", text: "x", context: ctx({ filePath: join(shop, "app", "models", "order.rb") }) });
    expect(d.project.id).toBe(models.id);
  });

  test("3. URL and app rules, most specific first", async () => {
    const w = world(adapter);
    const shop = w.registry.save({ name: "shop" });
    const blog = w.registry.save({ name: "blog" });
    w.registry.addRule(blog.id, "url", "github.com/*");
    w.registry.addRule(shop.id, "url", "github.com/me/shop/*");
    w.registry.addRule(blog.id, "app", "com.figma.Desktop");
    const a = await w.coordinator.route({ id: "1", text: "x", context: ctx({ url: "https://github.com/me/shop/pull/3?x=1" }) });
    expect(a).toMatchObject({ step: "rule" });
    expect(a.project.id).toBe(shop.id);
    const b = await w.coordinator.route({ id: "2", text: "x", context: ctx({ url: "https://github.com/other/thing" }) });
    expect(b.project.id).toBe(blog.id);
    const c = await w.coordinator.route({ id: "3", text: "x", context: ctx({ app: { name: "Figma", bundleID: "com.figma.Desktop", pid: 1 } }) });
    expect(c.project.id).toBe(blog.id);
  });

  test("4. a follow-up from the same app within a few minutes goes to the same project", async () => {
    let t = 1_000_000;
    const w = world(adapter, { clock: () => t });
    const shop = w.registry.save({ name: "shop" });
    const first = { id: "1", text: "@shop explain the checkout flow", context: ctx({ windowTitle: "Docs" }) };
    w.coordinator.noteRouted(first, await w.coordinator.route(first));
    t += 60_000;
    const d = await w.coordinator.route({ id: "2", text: "what about refunds?", context: ctx({ windowTitle: "Other" }) });
    expect(d).toMatchObject({ step: "recent" });
    expect(d.project.id).toBe(shop.id);
    const same = await w.coordinator.route({ id: "3", text: "summarize", context: ctx({ windowTitle: "Docs" }) });
    expect(same.step).toBe("recent");
    // A new question from another app isn't a follow-up, however it starts.
    const mail = ctx({ app: { name: "Mail", bundleID: "com.apple.mail", pid: 2 }, windowTitle: "Inbox" });
    expect((await w.coordinator.route({ id: "4", text: "why is the sky blue", context: mail })).step).toBe("fallback");
    expect((await w.coordinator.route({ id: "5", text: "why is the sky blue", context: ctx({ windowTitle: "Other" }) })).step).toBe("fallback");
    t += 10 * 60_000;
    expect((await w.coordinator.route({ id: "6", text: "what about refunds?", context: ctx() })).step).toBe("fallback");
  });

  test("5. the model picks a project when it's confident", async () => {
    const c = classifier({ project: "game", confidence: 0.9, why: "mentions the game idea" });
    const w = world(adapter, { classifier: c });
    const game = w.registry.save({ name: "game", description: "A roguelike prototype" });
    const d = await w.coordinator.route({ id: "1", text: "save this for the game idea", context: ctx() });
    expect(d).toMatchObject({ step: "model", confidence: 0.9, reason: "mentions the game idea" });
    expect(d.project.id).toBe(game.id);
  });

  test("6. low confidence goes to Inbox and offers the guess", async () => {
    const w = world(adapter, { classifier: classifier({ project: "game", confidence: 0.3, why: "" }) });
    const game = w.registry.save({ name: "game" });
    const d = await w.coordinator.route({ id: "1", text: "hmm", context: ctx() });
    expect(d.step).toBe("fallback");
    expect(d.project.id).toBe(INBOX_ID);
    expect(d.ask.map((p) => p.id)).toEqual([game.id]);
  });

  test("6. a name the model made up, or a failed call, falls back to Inbox", async () => {
    const w = world(adapter, { classifier: classifier({ project: "imaginary", confidence: 0.99, why: "" }) });
    w.registry.save({ name: "game" });
    expect((await w.coordinator.route({ id: "1", text: "x", context: ctx() })).project.id).toBe(INBOX_ID);
    const w2 = world(adapter, { classifier: classifier(undefined) });
    w2.registry.save({ name: "game" });
    expect((await w2.coordinator.route({ id: "1", text: "x", context: ctx() })).step).toBe("fallback");
  });

  test("the model isn't asked when there are no projects, or for blocked context beyond the app name", async () => {
    const c = classifier({ project: "Inbox", confidence: 1, why: "" });
    const w = world(adapter, { classifier: c });
    await w.coordinator.route({ id: "1", text: "x", context: ctx() });
    expect(c.calls).toBe(0);
    let seen = "";
    const w2 = world(adapter, { classifier: { async classify(i) { seen = i.context; return undefined; } } });
    w2.registry.save({ name: "game" });
    await w2.coordinator.route({ id: "1", text: "x", context: ctx({ blockedReason: "1Password", windowTitle: "Vault" }) });
    expect(seen).toBe("app: Safari");
  });
});

describe("reroutes teach rules", () => {
  test("a page on a code host teaches its repository", () => {
    const w = world(adapter);
    const shop = w.registry.save({ name: "shop" });
    const r = w.coordinator.learnFromReroute(ctx({ url: "https://github.com/me/shop/issues/9" }), shop);
    expect(r).toMatchObject({ kind: "url", pattern: "github.com/me/shop/*", source: "reroute" });
  });

  test("reroutes never teach app rules, broad site rules, or anything for Inbox or folders", () => {
    const w = world(adapter);
    const shop = w.registry.save({ name: "shop" });
    const learn = (over: Record<string, unknown>, to = shop) => w.coordinator.learnFromReroute(ctx(over), to);
    expect(learn({ app: { name: "Mail", bundleID: "com.apple.mail", pid: 1 } })).toBeUndefined();
    expect(learn({ url: "https://github.com/notifications" })).toBeUndefined();
    expect(learn({ url: "http://localhost:3000/admin" })).toBeUndefined();
    expect(learn({ url: "https://news.site/" })).toBeUndefined();
    expect(learn({ url: "https://mail.google.com/mail/u/0/#inbox" })).toBeUndefined();
    expect(learn({ url: "https://x.com/a" }, w.registry.inbox)).toBeUndefined();
    expect(learn({ cwd: "/tmp", url: "https://x.com/a" })).toBeUndefined();
    expect(learn({ url: "https://docs.google.com/document/d/abc123/edit" })?.pattern).toBe("docs.google.com/document/d/abc123/*");
    expect(learn({ url: "https://blog.example.com/recipes/1" })?.pattern).toBe("blog.example.com/recipes/*");
    // Segments every page shares would take the whole site.
    expect(learn({ url: "https://en.wikipedia.org/wiki/Rust" })?.pattern).toBe("en.wikipedia.org/wiki/Rust/*"); // one article, not all of Wikipedia
    expect(learn({ url: "https://news.ycombinator.com/item?id=1" })).toBeUndefined();
    expect(learn({ url: "https://stackoverflow.com/questions/123/how" })).toBeUndefined();
    expect(learn({ url: "https://docs.example.com/docs/billing/limits" })?.pattern).toBe("docs.example.com/docs/billing/*");
  });

  test("a newer reroute for the same pattern replaces the old rule", () => {
    const w = world(adapter);
    const a = w.registry.save({ name: "a" });
    const b = w.registry.save({ name: "b" });
    w.coordinator.learnFromReroute(ctx({ url: "https://news.site/x/1" }), a);
    w.coordinator.learnFromReroute(ctx({ url: "https://news.site/x/2" }), b);
    expect(w.registry.rules().map((r) => [r.pattern, r.projectId])).toEqual([["news.site/x/*", b.id]]);
  });
});

describe("registry", () => {
  test("names are unique regardless of case, and Inbox stays", () => {
    const w = world(adapter);
    w.registry.save({ name: "Shop" });
    expect(() => w.registry.save({ name: "shop" })).toThrow();
    expect(w.registry.remove(INBOX_ID)).toBe(false);
    expect(() => w.registry.save({ id: INBOX_ID, name: "Other" })).toThrow();
    expect(w.registry.byName("@SHOP")?.name).toBe("Shop");
  });

  test("projects without a folder get one under Superclick's folder", () => {
    const w = world(adapter);
    const p = w.registry.save({ name: "Game Idea" });
    expect(p.paths[0]).toBe(join(w.home, "Projects", "game-idea"));
    expect(w.registry.folder(p)).toBe(p.paths[0]!);
    expect(w.registry.inbox.paths[0]).toBe(join(w.home, "Inbox"));
  });

  test("a rule can't match every site", () => {
    const w = world(adapter);
    const p = w.registry.save({ name: "x" });
    for (const bad of ["*", "/*", "*/*", "  "]) expect(() => w.registry.addRule(p.id, "url", bad)).toThrow();
  });

  test("removing a project removes its rules", () => {
    const w = world(adapter);
    const p = w.registry.save({ name: "x" });
    w.registry.addRule(p.id, "url", "x.com/*");
    w.registry.remove(p.id);
    expect(w.registry.rules()).toHaveLength(0);
  });
});

describe("path safety", () => {
  test("a symlinked or differently cased path to a project is the same project", async () => {
    const w = world(adapter);
    const shop = repo();
    const first = await w.coordinator.route({ id: "1", text: "x", context: ctx({ cwd: shop }) });
    const link = join(mkdtempSync(join(tmpdir(), "link-")), "shop");
    symlinkSync(shop, link);
    const viaLink = await w.coordinator.route({ id: "2", text: "x", context: ctx({ cwd: link }) });
    expect(viaLink.project.id).toBe(first.project.id);
    expect(w.registry.list()).toHaveLength(2);
  });

  test("the home folder is never adopted as a project, and a removed repo stays removed", async () => {
    const w = world(adapter);
    const home = homedir();
    expect(w.registry.adoptRepo(home)).toBeUndefined();
    expect(w.registry.adoptRepo("/")).toBeUndefined();
    const shop = repo();
    const p = w.registry.adoptRepo(shop)!;
    w.registry.remove(p.id);
    expect(w.registry.adoptRepo(shop)).toBeUndefined();
    expect((await w.coordinator.route({ id: "1", text: "x", context: ctx({ cwd: shop }) })).step).toBe("fallback");
    // Adding it back by hand works.
    w.registry.save({ name: "shop", paths: [shop] });
    expect((await w.coordinator.route({ id: "2", text: "x", context: ctx({ cwd: shop }) })).step).toBe("path");
  });

  test("URL globs run in linear time", () => {
    const url = "a/".repeat(1000) + "b";
    const t = performance.now();
    expect(urlMatches("*/*/*/*/*/*/*/shop/*", url)).toBe(false);
    expect(performance.now() - t).toBeLessThan(50);
    expect(glob("a*b*c", "axxbyyc")).toBe(true);
    expect(glob("a*b*c", "axxbyy")).toBe(false);
  });
});

test("saving a project that was just removed doesn't bring it back", () => {
  const w = world(adapter);
  const p = w.registry.save({ name: "gone" });
  w.registry.remove(p.id);
  expect(() => w.registry.save({ id: p.id, name: "gone", description: "edited" })).toThrow("removed");
  expect(w.registry.byName("gone")).toBeUndefined();
});

describe("helpers", () => {
  test("mentions", () => {
    expect(findMention("@shop fix it")).toBe("shop");
    expect(findMention("fix it @shop")).toBe("shop");
    expect(findMention("me@shop.com")).toBeUndefined();
    expect(stripMention("@shop fix it", "shop")).toBe("fix it");
    expect(stripMention("please @shop fix it", "shop")).toBe("please fix it");
  });

  test("URLs", () => {
    expect(normalizeURL("https://www.GitHub.com/me/shop/?q=1#x")).toBe("github.com/me/shop");
    expect(normalizeURL("file:///etc/passwd")).toBeUndefined();
    expect(urlMatches("github.com/me/shop/*", "github.com/me/shop")).toBe(true);
    expect(urlMatches("github.com/me/shop/*", "github.com/me/shop/pull/1")).toBe(true);
    expect(urlMatches("github.com/me/shop/*", "github.com/me/shopping")).toBe(false);
    expect(urlMatches("*.example.com/*", "docs.example.com/a")).toBe(true);
    expect(ruleForURL("https://github.com/me/shop/pull/3")).toBe("github.com/me/shop/*");
    expect(ruleForURL("https://blog.example.com/post/1")).toBeUndefined();
    expect(ruleForURL("https://blog.example.com/recipes/1")).toBe("blog.example.com/recipes/*");
  });
});
