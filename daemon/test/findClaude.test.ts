import { expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findClaude } from "../src/agents/findClaude.ts";

const fakeClaude = (dir: string) => {
  mkdirSync(dir, { recursive: true });
  const p = join(dir, "claude");
  writeFileSync(p, "#!/bin/sh\necho 2.1.0\n");
  chmodSync(p, 0o755);
  return p;
};

test("finds Claude Code on the PATH, then where the installers put it", () => {
  const home = mkdtempSync(join(tmpdir(), "sc-claude-"));
  const bin = fakeClaude(join(home, "bin"));
  expect(findClaude({ env: { PATH: `/nowhere:${join(home, "bin")}` }, home })).toMatchObject({ source: "installed", path: bin });
  // launchd's bare PATH: the native installer's ~/.local/bin is still found.
  const local = fakeClaude(join(home, ".local", "bin"));
  expect(findClaude({ env: { PATH: "/usr/bin:/bin" }, home })).toMatchObject({ source: "installed", path: local });
  expect(findClaude({ env: { SUPERCLICK_CLAUDE_PATH: bin, PATH: "" }, home })).toMatchObject({ source: "env", path: bin });
});

test("without one, the app's daemon reports it missing; development falls back to the SDK's copy", () => {
  const home = mkdtempSync(join(tmpdir(), "sc-noclaude-"));
  expect(findClaude({ env: { PATH: "/nowhere", SUPERCLICK_COMPILED: "1" }, home }).source).toBe("missing");
  expect(findClaude({ env: { PATH: "/nowhere" }, home }).source).toBe("sdk");
});
