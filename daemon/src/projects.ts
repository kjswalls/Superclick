import type { Database } from "bun:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import { superclickHome } from "./auth.ts";

// The project registry (SPEC: "Project: id, name, folder paths, one-line
// description, URL and app rules"). Each project is a folder with its own
// long-lived agent session; Inbox is the built-in project for everything else.

export interface Project {
  id: string;
  name: string;
  /** Folders that belong to the project. The first is where its session runs. */
  paths: string[];
  description: string;
  agent: string;
}

export interface Rule {
  id: number;
  projectId: string;
  kind: "url" | "app";
  pattern: string;
  /** "user" for rules made in Settings, "reroute" for ones learned from a reroute. */
  source: "user" | "reroute";
}

export const INBOX_ID = "inbox";

/** Where Inbox, and projects made without a folder, keep their files. */
export function defaultFolder(name: string, home = superclickHome()): string {
  if (name === "Inbox") return join(home, "Inbox");
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "project";
  return join(home, "Projects", slug);
}

export function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** The nearest folder at or above `start` that holds a .git, or undefined. */
export function gitRoot(start: string): string | undefined {
  let dir = start;
  for (let i = 0; i < 40; i++) {
    if (existsSync(join(dir, ".git"))) return dir;
    const up = dirname(dir);
    if (up === dir) return undefined;
    dir = up;
  }
  return undefined;
}

/**
 * A path in a form that compares reliably: symlinks followed (for the part that
 * exists), and case folded on macOS, whose volumes are case-insensitive by default.
 */
export function canonical(path: string): string {
  let p = resolve(path);
  let rest = "";
  // realpath only works on what exists; resolve the longest existing prefix.
  for (let i = 0; i < 64; i++) {
    try {
      p = realpathSync(p) + rest;
      break;
    } catch {
      const up = dirname(p);
      if (up === p) {
        p = p + rest;
        break;
      }
      rest = sep + basename(p) + rest;
      p = up;
    }
  }
  return process.platform === "darwin" ? p.toLowerCase() : p;
}

/** True when `path` is `folder` or inside it, after following symlinks. */
export function within(path: string, folder: string): boolean {
  const p = canonical(path);
  const f = canonical(folder);
  return p === f || p.startsWith(f.endsWith(sep) ? f : f + sep);
}

/** "https://www.github.com/me/shop/pull/3?x=1" → "github.com/me/shop/pull/3". */
export function normalizeURL(url: string): string | undefined {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return undefined;
    const host = u.hostname.toLowerCase().replace(/^www\./, "");
    const path = u.pathname.replace(/\/+$/, "");
    return host + path;
  } catch {
    return undefined;
  }
}

/** `*` matches any run of characters. Linear time (no regex), so no pattern can stall the daemon. */
export function glob(pattern: string, text: string): boolean {
  let p = 0, t = 0, star = -1, mark = 0;
  while (t < text.length) {
    if (p < pattern.length && pattern[p] === "*") {
      star = p++;
      mark = t;
    } else if (p < pattern.length && pattern[p] === text[t]) {
      p++;
      t++;
    } else if (star >= 0) {
      p = star + 1;
      t = ++mark;
    } else {
      return false;
    }
  }
  while (p < pattern.length && pattern[p] === "*") p++;
  return p === pattern.length;
}

/** A glob over normalized URLs: `*` is any run of characters; "a/*" also matches "a". */
export function urlMatches(pattern: string, url: string): boolean {
  const p = pattern.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/^www\./, "");
  const u = url.toLowerCase().slice(0, 2048);
  if (p.endsWith("/*") && u === p.slice(0, -2)) return true;
  return glob(p, u);
}

const CODE_HOSTS = new Set(["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]);
/** Sites where one host holds everyone's documents, so a rule must name the document. */
const SHARED_HOSTS = [
  /(^|\.)google\.com$/, /(^|\.)notion\.(so|site)$/, /(^|\.)figma\.com$/, /(^|\.)slack\.com$/, /(^|\.)atlassian\.net$/,
  /(^|\.)linear\.app$/, /(^|\.)dropbox\.com$/, /(^|\.)office\.com$/, /(^|\.)sharepoint\.com$/, /(^|\.)live\.com$/,
  /(^|\.)icloud\.com$/, /(^|\.)x\.com$/, /(^|\.)twitter\.com$/, /(^|\.)reddit\.com$/, /(^|\.)youtube\.com$/,
  /(^|\.)linkedin\.com$/, /(^|\.)medium\.com$/, /(^|\.)substack\.com$/, /(^|\.)discord\.com$/, /(^|\.)claude\.ai$/,
];

/** Mail, chat and calendars: every message is about something different, so nothing is learned there. */
const NEVER_LEARN = [
  /^mail\./, /^outlook\./, /^calendar\./, /^chat\./, /^web\.whatsapp\.com$/, /^messages\./, /^teams\./,
  /(^|\.)slack\.com$/, /(^|\.)discord\.com$/, /(^|\.)telegram\.org$/, /(^|\.)fastmail\.com$/, /(^|\.)proton\.me$/,
  /(^|\.)superhuman\.com$/, /(^|\.)hey\.com$/,
];

/**
 * The rule a reroute teaches (SPEC: "Reroutes become new rules"), or nothing
 * when no narrow rule fits. On code hosts it's the repository
 * ("github.com/me/shop/*"); on shared sites, the document; elsewhere the site
 * and its first path segment. Local addresses and bare hosts teach nothing.
 */
export function ruleForURL(url: string): string | undefined {
  const n = normalizeURL(url);
  if (!n) return undefined;
  const [hostPort, ...rest] = n.split("/").filter((x, i) => i === 0 || x);
  const host = hostPort?.split(":")[0];
  if (!host || host === "localhost" || /^[\d.]+$/.test(host) || host.endsWith(".local") || host.includes("[")) return undefined;
  if (NEVER_LEARN.some((r) => r.test(host))) return undefined;
  if (CODE_HOSTS.has(host)) return rest.length >= 2 ? `${host}/${rest[0]}/${rest[1]}/*` : undefined;
  if (SHARED_HOSTS.some((r) => r.test(host))) return rest.length >= 3 ? `${host}/${rest.slice(0, 3).join("/")}/*` : undefined;
  return rest.length >= 1 ? `${host}/${rest[0]}/*` : undefined;
}

interface ProjectRow {
  id: string;
  name: string;
  paths: string;
  description: string;
  agent: string;
}

const toProject = (r: ProjectRow): Project => ({
  id: r.id,
  name: r.name,
  paths: safePaths(r.paths),
  description: r.description,
  agent: r.agent,
});

function safePaths(json: string): string[] {
  try {
    const v = JSON.parse(json);
    return Array.isArray(v) ? v.filter((p): p is string => typeof p === "string") : [];
  } catch {
    return [];
  }
}

export class ProjectRegistry {
  constructor(private readonly db: Database, private readonly home = superclickHome()) {
    const inbox = this.get(INBOX_ID);
    if (!inbox) {
      this.db.query("INSERT INTO projects (id, name, paths, description, agent, created_at) VALUES (?, ?, ?, ?, ?, ?)")
        .run(INBOX_ID, "Inbox", JSON.stringify([defaultFolder("Inbox", home)]),
          "Everything that isn't about one of the projects: notes, one-off questions, things to sort later.",
          "Claude Code", Date.now());
    }
  }

  get inbox(): Project {
    return this.get(INBOX_ID)!;
  }

  list(): Project[] {
    const rows = this.db.query("SELECT id, name, paths, description, agent FROM projects ORDER BY id = 'inbox', name").all() as ProjectRow[];
    return rows.map(toProject);
  }

  get(id: string): Project | undefined {
    const r = this.db.query("SELECT id, name, paths, description, agent FROM projects WHERE id = ?").get(id) as ProjectRow | null;
    return r ? toProject(r) : undefined;
  }

  byName(name: string): Project | undefined {
    const n = name.trim().replace(/^@/, "");
    if (!n) return undefined;
    const r = this.db.query("SELECT id, name, paths, description, agent FROM projects WHERE name = ? COLLATE NOCASE").get(n) as ProjectRow | null;
    return r ? toProject(r) : undefined;
  }

  /** Creates or updates a project. Names are unique (case-insensitive); Inbox can't be renamed. */
  save(p: { id?: string; name: string; paths?: string[]; description?: string; agent?: string }): Project {
    const name = p.name.trim().replace(/^@/, "").slice(0, 60);
    if (!name) throw new Error("A project needs a name.");
    if (/\s/.test(name) && name.split(/\s+/).length > 4) throw new Error("Keep project names short.");
    const existing = p.id ? this.get(p.id) : undefined;
    const clash = this.byName(name);
    if (clash && clash.id !== existing?.id) throw new Error(`There's already a project called ${clash.name}.`);
    const paths = (p.paths ?? existing?.paths ?? []).map((x) => resolve(x)).filter((x, i, a) => a.indexOf(x) === i);
    for (const x of paths) this.db.query("DELETE FROM forgotten WHERE path = ?").run(canonical(x));
    if (existing) {
      if (existing.id === INBOX_ID && name.toLowerCase() !== "inbox") throw new Error("Inbox can't be renamed.");
      this.db.query("UPDATE projects SET name = ?, paths = ?, description = ?, agent = ? WHERE id = ?")
        .run(name, JSON.stringify(paths.length ? paths : existing.paths), (p.description ?? existing.description).slice(0, 300),
          p.agent ?? existing.agent, existing.id);
      return this.get(existing.id)!;
    }
    const id = randomUUID();
    const folders = paths.length ? paths : [defaultFolder(name, this.home)];
    this.db.query("INSERT INTO projects (id, name, paths, description, agent, created_at) VALUES (?, ?, ?, ?, ?, ?)")
      .run(id, name, JSON.stringify(folders), (p.description ?? "").slice(0, 300), p.agent ?? "Claude Code", Date.now());
    return this.get(id)!;
  }

  remove(id: string): boolean {
    if (id === INBOX_ID) return false;
    // Its folders aren't adopted again just because a request comes from them.
    for (const f of this.get(id)?.paths ?? []) this.db.query("INSERT OR IGNORE INTO forgotten (path) VALUES (?)").run(canonical(f));
    this.db.query("DELETE FROM sessions WHERE project_id = ?").run(id);
    return this.db.query("DELETE FROM projects WHERE id = ?").run(id).changes > 0;
  }

  /** The folder a project's session runs in, created if it's one of ours. */
  folder(p: Project): string {
    const f = p.paths[0] ?? defaultFolder(p.name, this.home);
    if (!isDir(f) && within(f, this.home)) mkdirSync(f, { recursive: true, mode: 0o700 });
    return f;
  }

  /** The project with the deepest folder that contains `path`. */
  matchPath(path: string): Project | undefined {
    let best: { p: Project; len: number } | undefined;
    for (const p of this.list()) {
      if (p.id === INBOX_ID) continue;
      for (const f of p.paths) {
        if (within(path, f) && (!best || f.length > best.len)) best = { p, len: f.length };
      }
    }
    return best?.p;
  }

  /**
   * A project for an unregistered git repository, named after its folder, or
   * nothing: the home folder, the disk root and Superclick's own folder are
   * never projects, and a repository whose project was removed stays removed.
   */
  adoptRepo(root: string): Project | undefined {
    const found = this.matchPath(root);
    if (found) return found;
    const c = canonical(root);
    if (c === canonical(homedir()) || c === canonical("/") || within(this.home, root)) return undefined;
    if (this.db.query("SELECT 1 FROM forgotten WHERE path = ?").get(c)) return undefined;
    let name = basename(root) || "project";
    for (let i = 2; this.byName(name); i++) name = `${basename(root)}-${i}`;
    return this.save({ name, paths: [root] });
  }

  rules(projectId?: string): Rule[] {
    const rows = (projectId
      ? this.db.query("SELECT id, project_id, kind, pattern, source FROM rules WHERE project_id = ? ORDER BY id").all(projectId)
      : this.db.query("SELECT id, project_id, kind, pattern, source FROM rules ORDER BY id").all()) as
      { id: number; project_id: string; kind: "url" | "app"; pattern: string; source: "user" | "reroute" }[];
    return rows.map((r) => ({ id: r.id, projectId: r.project_id, kind: r.kind, pattern: r.pattern, source: r.source }));
  }

  /** Adds a rule, replacing any rule with the same pattern (a newer reroute wins). */
  addRule(projectId: string, kind: "url" | "app", pattern: string, source: "user" | "reroute" = "user"): Rule {
    const pat = pattern.trim();
    if (!pat || pat.length > 300) throw new Error("A rule needs a pattern.");
    if (kind === "url" && /^\*?\/?\*?$/.test(pat)) throw new Error("That rule would match every site.");
    if (!this.get(projectId)) throw new Error("No such project.");
    this.db.query(
      "INSERT INTO rules (project_id, kind, pattern, source, created_at) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT (kind, pattern) DO UPDATE SET project_id = excluded.project_id, source = excluded.source, created_at = excluded.created_at",
    ).run(projectId, kind, pat, source, Date.now());
    return this.rules().find((r) => r.kind === kind && r.pattern === pat)!;
  }

  removeRule(id: number): boolean {
    return this.db.query("DELETE FROM rules WHERE id = ?").run(id).changes > 0;
  }

  /** The most specific URL rule that matches, else an app rule. */
  matchRule(url: string | undefined, bundleID: string | undefined): { project: Project; rule: Rule } | undefined {
    const all = this.rules();
    const n = url ? normalizeURL(url) : undefined;
    if (n) {
      const hits = all.filter((r) => r.kind === "url" && urlMatches(r.pattern, n)).sort((a, b) => b.pattern.length - a.pattern.length);
      for (const r of hits) {
        const p = this.get(r.projectId);
        if (p) return { project: p, rule: r };
      }
    }
    if (bundleID) {
      const r = all.find((x) => x.kind === "app" && x.pattern === bundleID);
      const p = r && this.get(r.projectId);
      if (r && p) return { project: p, rule: r };
    }
    return undefined;
  }
}
