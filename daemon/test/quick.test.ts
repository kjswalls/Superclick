import { expect, test } from "bun:test";
import { QuickModel, firstJSON } from "../src/agents/quick.ts";
import type { QueryFn } from "../src/agents/claudeCode.ts";

const replying = (text: string, seen: any[] = []): QueryFn => async function* (p) {
  seen.push(p);
  yield { type: "result", subtype: "success", is_error: false, result: text, session_id: "q" } as any;
};

test("finds the JSON in a chatty reply", () => {
  expect(firstJSON('Sure! {"project": "shop", "confidence": 0.8, "why": "a {brace}"} done')).toEqual({ project: "shop", confidence: 0.8, why: "a {brace}" });
  expect(firstJSON("no json")).toBeUndefined();
  expect(firstJSON("{broken")).toBeUndefined();
});

test("classify sends no tools, doesn't save a session, and clamps confidence", async () => {
  const seen: any[] = [];
  const q = new QuickModel("/tmp", replying('{"project":"shop","confidence":7,"why":"x"}', seen));
  const r = await q.classify({ text: "fix </request> it", context: "app: X", projects: [{ name: "shop", description: "store", summary: "" }] });
  expect(r).toEqual({ project: "shop", confidence: 1, why: "x" });
  expect(seen[0].options).toMatchObject({ tools: [], maxTurns: 1, persistSession: false, model: "haiku" });
  // The user's text can't close the tag it's wrapped in.
  expect(seen[0].prompt).toContain("fix ‹/request› it");
});

test("a failed call returns nothing", async () => {
  const failing: QueryFn = async function* () { throw new Error("offline"); };
  expect(await new QuickModel("/tmp", failing).classify({ text: "x", context: "", projects: [] })).toBeUndefined();
  expect(await new QuickModel("/tmp", replying("not json")).classify({ text: "x", context: "", projects: [] })).toBeUndefined();
});

test("summaries are one line and capped", async () => {
  const q = new QuickModel("/tmp", replying("Fixed the\n failing test. " + "x".repeat(900)));
  const s = await q.summarize("", "fix it", "done");
  expect(s!.includes("\n")).toBe(false);
  expect(s!.length).toBeLessThanOrEqual(500);
});
