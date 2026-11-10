import type { Database } from "bun:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, statSync } from "node:fs";
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

/** True when `path` is `folder` or inside it. */
export function within(path: string, folder: string): boolean {
  const p = resolve(path);
  const f = resolve(folder);
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

/** A glob over normalized URLs: `*` is any run of characters; "a/*" also matches "a". */
export function urlMatches(pattern: string, url: string): boolean {
  const p = pattern.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/^www\./, "");
  const esc = (s: string) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  const body = p.endsWith("/*") ? `${esc(p.slice(0, -2))}(/.*)?` : esc(p);
  return new RegExp(`^${body}$`).test(url.toLowerCase());
}

const CODE_HOSTS = new Set(["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]);

/**
 * The rule a reroute teaches (SPEC: "Reroutes become new rules"). On code
 * hosts it's the repository ("github.com/me/shop/*"); elsewhere the site.
 */
export function ruleForURL(url: string): string | undefined {
  const n = normalizeURL(url);
  if (!n) return undefined;
  const [host, ...rest] = n.split("/");
  if (!host) return undefined;
  if (CODE_HOSTS.has(host) && rest.length >= 2) return `${host}/${rest[0]}/${rest[1]}/*`;
  return `${host}/*`;
}

/** Apps whose window says nothing about the project on its own, so a reroute shouldn't make an app rule. */
const GENERIC_APPS = new Set([
  "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
  "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
  "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
  "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty",
  "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
  "com.jetbrains.intellij", "com.sublimetext.4", "com.apple.finder", "com.apple.TextEdit",
]);

export function canLearnAppRule(bundleID: string | undefined): boolean {
  return !!bundleID && !GENERIC_APPS.has(bundleID) && !bundleID.startsWith("com.jetbrains.");
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

  /** A project for an unregistered git repository, named after its folder. */
  adoptRepo(root: string): Project {
    const found = this.matchPath(root);
    if (found) return found;
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
