import { spawnSync } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

// Superclick uses the Claude Code installed on the Mac (signed in with the
// user's own account), rather than shipping a copy of its own. This finds it.

export interface ClaudeStatus {
  /** "env": SUPERCLICK_CLAUDE_PATH. "installed": found on the Mac. "sdk": the Agent SDK's own copy (development only). */
  source: "env" | "installed" | "sdk" | "missing";
  path?: string;
  version?: string;
}

/** The official installer; shown to the user, never run by Superclick. */
export const INSTALL_COMMAND = "curl -fsSL https://claude.ai/install.sh | bash";
export const INSTALL_URL = "https://code.claude.com/docs/en/setup";
export const MISSING_MESSAGE =
  "Claude Code isn't installed on this Mac. Install it (Superclick Settings → Agents shows how), then run `claude` once in Terminal to sign in.";

/** Where the installers put it, for when the daemon runs without the user's shell PATH. */
function knownPlaces(home = homedir()): string[] {
  return [
    join(home, ".local", "bin", "claude"), // the native installer
    join(home, ".claude", "local", "claude"), // older local installs
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(home, ".npm-global", "bin", "claude"),
    join(home, ".bun", "bin", "claude"),
    join(home, ".volta", "bin", "claude"),
  ];
}

function executable(p: string): boolean {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function version(path: string): string | undefined {
  try {
    const r = spawnSync(path, ["--version"], { timeout: 4000, encoding: "utf8" });
    const v = r.status === 0 ? r.stdout.trim().split("\n")[0] : undefined;
    return v ? v.slice(0, 80) : undefined;
  } catch {
    return undefined;
  }
}

let cached: { at: number; status: ClaudeStatus } | undefined;

/**
 * Finds Claude Code, checking again at most every 10 seconds, so installing it
 * works without restarting anything. `fresh` checks now.
 */
export function findClaude(opts: { fresh?: boolean; env?: NodeJS.ProcessEnv; home?: string } = {}): ClaudeStatus {
  const env = opts.env ?? process.env;
  if (!opts.fresh && !opts.env && cached && Date.now() - cached.at < 10_000) return cached.status;
  let status: ClaudeStatus;
  const fromEnv = env.SUPERCLICK_CLAUDE_PATH;
  if (fromEnv && executable(fromEnv)) {
    status = { source: "env", path: fromEnv };
  } else {
    const onPath = (env.PATH ?? "").split(delimiter).filter(Boolean).map((d) => join(d, "claude"));
    const found = [...onPath, ...knownPlaces(opts.home)].find(executable);
    if (found) status = { source: "installed", path: found };
    // `bun run start` in development can fall back to the SDK's own copy; the app's compiled daemon can't.
    else status = env.SUPERCLICK_COMPILED ? { source: "missing" } : { source: "sdk" };
  }
  if (status.path && !opts.env) status.version = version(status.path);
  if (!opts.env) cached = { at: Date.now(), status };
  return status;
}
