import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** ~/Library/Application Support/Superclick, or $SUPERCLICK_HOME (used by tests). */
export function superclickHome(): string {
  return process.env.SUPERCLICK_HOME ?? join(homedir(), "Library", "Application Support", "Superclick");
}

/**
 * The shared secret the app presents as "Authorization: Bearer <token>".
 * Created once with mode 0600, so only this user's processes can read it.
 */
export function loadOrCreateToken(dir = superclickHome()): string {
  const path = join(dir, "daemon.token");
  if (existsSync(path)) {
    const t = readFileSync(path, "utf8").trim();
    if (t.length >= 32) {
      // Tighten it again in case something loosened it.
      chmodSync(path, 0o600);
      return t;
    }
  }
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const token = randomBytes(32).toString("hex");
  writeFileSync(path, token + "\n", { mode: 0o600 });
  chmodSync(path, 0o600);
  return token;
}

export function tokenMatches(header: string | null, token: string): boolean {
  if (!header?.startsWith("Bearer ")) return false;
  const given = Buffer.from(header.slice(7).trim());
  const want = Buffer.from(token);
  return given.length === want.length && timingSafeEqual(given, want);
}
