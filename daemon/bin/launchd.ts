// Set-up for the compiled daemon when macOS starts it at login (a LaunchAgent).
// launchd gives it a bare environment: PATH is /usr/bin:/bin:/usr/sbin:/sbin and
// nothing from the user's shell profile, so Claude Code's Bash tool wouldn't
// find Homebrew's git, node or bun. And launchd has nowhere private to put
// output, so the daemon keeps its own owner-only log.
import { spawnSync } from "node:child_process";
import { appendFileSync, chmodSync, mkdirSync, openSync, closeSync, statSync, truncateSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { format } from "node:util";

export function prepareLaunchdEnv() {
  if (process.stdout.isTTY) return; // started by hand in a Terminal: leave it as it is

  // The login shell's PATH, as a Terminal would have it.
  const shell = process.env.SHELL || "/bin/zsh";
  try {
    const r = spawnSync(shell, ["-l", "-c", 'printf "%s" "$PATH"'], { timeout: 3000, encoding: "utf8" });
    if (r.status === 0 && r.stdout.includes("/")) process.env.PATH = r.stdout.trim();
  } catch {
    // Fall through to the usual places.
  }
  const want = ["/opt/homebrew/bin", "/usr/local/bin", join(homedir(), ".local", "bin"), join(homedir(), ".bun", "bin")];
  const have = (process.env.PATH ?? "").split(":");
  process.env.PATH = [...have, ...want.filter((p) => !have.includes(p))].filter(Boolean).join(":");

  // ~/Library/Logs/Superclick/daemon.log, readable only by the user, started over past 5 MB.
  const dir = join(homedir(), "Library", "Logs", "Superclick");
  const file = join(dir, "daemon.log");
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    closeSync(openSync(file, "a", 0o600));
    chmodSync(file, 0o600);
    if (statSync(file).size > 5_000_000) truncateSync(file, 0);
    const write = (...args: unknown[]) => {
      try {
        appendFileSync(file, `${new Date().toISOString()} ${format(...args)}\n`);
      } catch {
        // A full disk mustn't stop the daemon.
      }
    };
    console.log = write;
    console.error = write;
    console.warn = write;
  } catch {
    // No log, then.
  }
}
