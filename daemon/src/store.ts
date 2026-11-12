import type { ContextBundle } from "./protocol.ts";

export interface StoredRequest {
  id: string;
  text: string;
  /** The request with its context as Markdown, kept so a reroute can resend it. */
  prompt?: string;
  fullPage: boolean;
  context: ContextBundle;
  receivedAt: number;
  /** The project it was routed to, so one project's agent only sees its own captures. */
  projectId?: string;
}

/**
 * Holds recent requests with the context captured at summon, in memory only.
 * From M5 the context MCP server answers agents' "fetch the rest of the page"
 * calls from here, so they see what you were looking at without a new capture
 * (DECISIONS, 2026-11-04). Old entries expire, and the store is capped.
 */
export class RequestStore {
  private byCapture = new Map<string, StoredRequest>();

  constructor(
    readonly maxEntries = 50,
    readonly ttlMs = 60 * 60 * 1000,
    private readonly clock: () => number = Date.now,
    /** Rough cap on the text held, so a few huge pages can't grow memory without bound. */
    readonly maxChars = 8_000_000,
  ) {}

  private chars = 0;

  private static sizeOf(r: StoredRequest): number {
    const c = r.context;
    return r.text.length + (r.prompt?.length ?? 0) + (c.page?.text.length ?? 0) + (c.selection?.length ?? 0) +
      (c.page?.headings.reduce((n, h) => n + h.text.length, 0) ?? 0);
  }

  private drop(id: string) {
    const r = this.byCapture.get(id);
    if (!r) return;
    this.chars -= RequestStore.sizeOf(r);
    this.byCapture.delete(id);
  }

  add(r: Omit<StoredRequest, "receivedAt">): StoredRequest {
    this.prune();
    const stored = { ...r, receivedAt: this.clock() };
    // Re-adding moves it to the newest position.
    this.drop(r.context.id);
    this.byCapture.set(r.context.id, stored);
    this.chars += RequestStore.sizeOf(stored);
    while (this.byCapture.size > this.maxEntries || (this.chars > this.maxChars && this.byCapture.size > 1)) {
      const oldest = this.byCapture.keys().next().value;
      if (oldest === undefined) break;
      this.drop(oldest);
    }
    return stored;
  }

  /** The newest stored request with this request id. */
  byRequest(id: string): StoredRequest | undefined {
    this.prune();
    let found: StoredRequest | undefined;
    for (const r of this.byCapture.values()) if (r.id === id) found = r;
    return found;
  }

  /** The most recent requests, newest first (M5's recent_context). */
  recent(n: number): StoredRequest[] {
    this.prune();
    return [...this.byCapture.values()].reverse().slice(0, n);
  }

  get(captureId: string): StoredRequest | undefined {
    this.prune();
    return this.byCapture.get(captureId);
  }

  get size(): number {
    this.prune();
    return this.byCapture.size;
  }

  /** One part of a captured page, or null when it wasn't captured (or was removed in the bubble). */
  part(captureId: string, part: "full" | "selection" | "outline"): string | null {
    const c = this.get(captureId)?.context;
    if (!c) return null;
    switch (part) {
      case "full":
        return c.page?.text ?? null;
      case "selection":
        return c.selection ?? null;
      case "outline":
        if (!c.page || c.page.headings.length === 0) return null;
        return c.page.headings.map((h) => `${"  ".repeat(Math.max(h.level - 1, 0))}- ${h.text}`).join("\n");
    }
  }

  private prune() {
    const cutoff = this.clock() - this.ttlMs;
    for (const [id, r] of this.byCapture) {
      if (r.receivedAt < cutoff) this.drop(id);
    }
  }
}
