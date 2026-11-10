import { expect, test } from "bun:test";
import { openDatabase } from "../src/db.ts";
import { Journal, changedPath } from "../src/journal.ts";

const names = (id: string) => ({ shop: { name: "shop", summary: "Fixing checkout." }, inbox: { name: "Inbox", summary: "" } } as any)[id];

test("cards group requests by project with what ran, changed and how it ended", () => {
  let t = 1000;
  const j = new Journal(openDatabase(":memory:"), () => t);
  j.add("shop", "r1", "request", { text: "fix the failing test" });
  t++; j.add("shop", "r1", "tool", { summary: "Bash bin/rails test" });
  t++; j.add("shop", "r1", "changed", { path: "/code/shop/app/order.rb" });
  t++; j.add("shop", "r1", "changed", { path: "/code/shop/app/order.rb" });
  t++; j.add("shop", "r1", "done", { text: "Fixed: the total was rounded twice." });
  t++; j.add("inbox", "r2", "request", { text: "summarize this" });
  const cards = j.catchUp(0, names, new Map([["r2", "waiting"]]));
  expect(cards.map((c) => c.project)).toEqual(["Inbox", "shop"]); // waiting first
  const shop = cards[1]!;
  expect(shop.summary).toBe("Fixing checkout.");
  expect(shop.requests[0]).toMatchObject({ id: "r1", text: "fix the failing test", status: "done", ran: ["Bash bin/rails test"],
    changed: ["/code/shop/app/order.rb"], answer: "Fixed: the total was rounded twice." });
  expect(cards[0]!.requests[0]!.status).toBe("waiting");
});

test("only activity since the given time counts, and a turn the daemon lost shows as failed", () => {
  let t = 1000;
  const j = new Journal(openDatabase(":memory:"), () => t);
  j.add("shop", "old", "request", { text: "old" });
  j.add("shop", "old", "done", { text: "ok" });
  t = 5000;
  j.add("shop", "new", "request", { text: "new" });
  const cards = j.catchUp(4000, names, new Map());
  expect(cards[0]!.requests.map((r) => [r.id, r.status])).toEqual([["new", "failed"]]);
});

test("a request still waiting shows however long ago it started, and a reroute keeps what changed", () => {
  let t = 1000;
  const j = new Journal(openDatabase(":memory:"), () => t);
  j.add("inbox", "w", "request", { text: "deploy" });
  j.add("inbox", "w", "changed", { path: "/tmp/a" });
  j.add("shop", "w", "request", { text: "deploy" });
  t = 9000;
  const cards = j.catchUp(5000, names, new Map([["w", "waiting"]]));
  expect(cards[0]!.requests[0]).toMatchObject({ id: "w", status: "waiting", changed: ["/tmp/a"] });
});

test("a rerouted request shows once, in its new project", () => {
  const j = new Journal(openDatabase(":memory:"));
  j.add("inbox", "r1", "request", { text: "save this" });
  j.add("shop", "r1", "request", { text: "save this" });
  j.add("shop", "r1", "done", { text: "Saved." });
  const cards = j.catchUp(0, names, new Map());
  expect(cards.map((c) => c.project)).toEqual(["shop"]);
});

test("old events are pruned", () => {
  let t = 0;
  const db = openDatabase(":memory:");
  const j = new Journal(db, () => t);
  j.add("shop", "r1", "request", { text: "x" });
  t = 8 * 24 * 60 * 60 * 1000;
  j.prune();
  expect((db.query("SELECT COUNT(*) AS n FROM events").get() as any).n).toBe(0);
});

test("changed paths come only from tools that write", () => {
  expect(changedPath("Write", { file_path: "/a" })).toBe("/a");
  expect(changedPath("NotebookEdit", { notebook_path: "/n.ipynb" })).toBe("/n.ipynb");
  expect(changedPath("Read", { file_path: "/a" })).toBeUndefined();
});
