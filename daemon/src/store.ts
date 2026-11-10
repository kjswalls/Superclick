import type { ContextBundle } from "./protocol.ts";

export interface StoredRequest {
  id: string;
  text: string;
  fullPage: boolean;
  context: ContextBundle;
  receivedAt: number;
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
  ) {}

  add(r: Omit<StoredRequest, "receivedAt">): StoredRequest {
    this.prune();
    const stored = { ...r, receivedAt: this.clock() };
    // Re-adding moves it to the newest position.
    this.byCapture.delete(r.context.id);
    this.byCapture.set(r.context.id, stored);
    while (this.byCapture.size > this.maxEntries) {
      const oldest = this.byCapture.keys().next().value;
      if (oldest === undefined) break;
      this.byCapture.delete(oldest);
    }
    return stored;
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
      if (r.receivedAt < cutoff) this.byCapture.delete(id);
    }
  }
}
