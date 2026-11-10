import { describe, expect, test } from "bun:test";
import { ProtocolError, parseClientMessage } from "../src/protocol.ts";
import { bundle } from "./fixtures.ts";


describe("parseClientMessage", () => {
  test("accepts a request with its context", () => {
    const m = parseClientMessage(JSON.stringify({ type: "request", id: "r1", text: "explain", fullPage: true, context: bundle() }));
    expect(m.type).toBe("request");
    if (m.type !== "request") return;
    expect(m.fullPage).toBe(true);
    expect(m.context.app.name).toBe("Safari");
  });

  test("defaults missing maps and fullPage", () => {
    const m = parseClientMessage(
      JSON.stringify({ type: "request", id: "r1", text: "x", context: bundle({ redactions: undefined, timings: undefined }) }),
    );
    if (m.type !== "request") throw new Error("wrong type");
    expect(m.fullPage).toBe(false);
    expect(m.context.redactions).toEqual({});
  });

  test.each([
    ["not json", "{"],
    ["no type", JSON.stringify({})],
    ["unknown type", JSON.stringify({ type: "rm -rf" })],
    ["empty text", JSON.stringify({ type: "request", id: "r", text: "  ", context: bundle() })],
    ["bad context", JSON.stringify({ type: "request", id: "r", text: "x", context: { id: "c" } })],
    ["non-string field", JSON.stringify({ type: "request", id: "r", text: "x", context: bundle({ url: 5 }) })],
    ["heading without text", JSON.stringify({ type: "request", id: "r", text: "x", context: bundle({ page: { text: "t", headings: [{ level: 1 }], method: "treeWalk" } }) })],
    ["heading with a huge level", JSON.stringify({ type: "request", id: "r", text: "x", context: bundle({ page: { text: "t", headings: [{ level: 1e9, text: "h" }], method: "treeWalk" } }) })],
    ["heading that isn't an object", JSON.stringify({ type: "request", id: "r", text: "x", context: bundle({ page: { text: "t", headings: [null], method: "treeWalk" } }) })],
    ["bad part", JSON.stringify({ type: "context.get", captureId: "c", part: "secrets" })],
  ])("rejects %s", (_, raw) => {
    expect(() => parseClientMessage(raw)).toThrow(ProtocolError);
  });
});
