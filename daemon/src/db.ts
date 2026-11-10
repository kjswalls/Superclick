import { Database } from "bun:sqlite";
import { chmodSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { superclickHome } from "./auth.ts";

// The local store (SPEC: "SQLite: projects, sessions, messages, routing log,
// rules"). One file, owner-only, in Superclick's Application Support folder.
// Request text and context stay in memory (store.ts); what's written here is
// what routing and catch-up need: projects, rules, sessions with their running
// summaries, the routing log, and session events.

const SCHEMA = `
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
  paths TEXT NOT NULL DEFAULT '[]',
  description TEXT NOT NULL DEFAULT '',
  agent TEXT NOT NULL DEFAULT 'Claude Code',
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('url', 'app')),
  pattern TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'user',
  created_at INTEGER NOT NULL,
  UNIQUE (kind, pattern)
);
CREATE TABLE IF NOT EXISTS sessions (
  project_id TEXT PRIMARY KEY,
  agent TEXT NOT NULL,
  sdk_session_id TEXT,
  summary TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS routing_log (
  request_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  step TEXT NOT NULL,
  reason TEXT NOT NULL,
  confidence REAL,
  app TEXT,
  at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  type TEXT NOT NULL,
  payload TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS forgotten (
  path TEXT PRIMARY KEY
);
CREATE INDEX IF NOT EXISTS events_by_request ON events (request_id);
CREATE INDEX IF NOT EXISTS events_by_project ON events (project_id, at);
CREATE INDEX IF NOT EXISTS events_by_at ON events (at);
`;

export function openDatabase(path = join(superclickHome(), "superclick.db")): Database {
  if (path !== ":memory:") mkdirSync(superclickHome(), { recursive: true, mode: 0o700 });
  const db = new Database(path, { create: true, strict: true });
  db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 2000;");
  db.exec(SCHEMA);
  if (path !== ":memory:") {
    for (const p of [path, `${path}-wal`, `${path}-shm`]) {
      try {
        chmodSync(p, 0o600);
      } catch {
        // The -wal and -shm files only exist once something is written.
      }
    }
  }
  return db;
}
