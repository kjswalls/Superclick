import { describe, expect, test } from "bun:test";
import { RequestStore } from "../src/store.ts";
import { parseContext } from "../src/protocol.ts";
import { bundle } from "./fixtures.ts";

const req = (id: string, over: Record<string, unknown> = {}) => ({
  id: `r-${id}`,
  text: "q",
  fullPage: false,
  context: parseContext(bundle({ id, ...over })),
});

describe("RequestStore", () => {
  test("serves parts of a captured page", () => {
    const s = new RequestStore();
    s.add(req("a"));
    expect(s.part("a", "full")).toBe("Intro. actors isolate state. End.");
    expect(s.part("a", "selection")).toBe("actors isolate state");
    expect(s.part("a", "outline")).toBe("- Intro");
    expect(s.part("missing", "full")).toBeNull();
  });

  test("returns null for parts removed in the bubble", () => {
    const s = new RequestStore();
    s.add(req("b", { page: undefined, selection: undefined }));
    expect(s.part("b", "full")).toBeNull();
    expect(s.part("b", "selection")).toBeNull();
    expect(s.part("b", "outline")).toBeNull();
  });

  test("caps the number of entries, dropping the oldest", () => {
    const s = new RequestStore(2);
    s.add(req("1"));
    s.add(req("2"));
    s.add(req("1")); // refreshes 1
    s.add(req("3"));
    expect(s.get("2")).toBeUndefined();
    expect(s.get("1")).toBeDefined();
    expect(s.size).toBe(2);
  });

  test("expires entries after the TTL", () => {
    let t = 0;
    const s = new RequestStore(10, 1000, () => t);
    s.add(req("x"));
    t = 999;
    expect(s.get("x")).toBeDefined();
    t = 1001;
    expect(s.get("x")).toBeUndefined();
  });
});
