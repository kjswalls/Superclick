import { query as sdkQuery, type CanUseTool, type Options, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { randomUUID } from "node:crypto";
import type { AgentAdapter, AgentEvent, AgentSession, Approval, SendInput } from "./adapter.ts";

export type QueryFn = (params: { prompt: string; options?: Options }) => AsyncIterable<SDKMessage>;

/** Tools that only read, so they run without asking (SPEC: "Read-only actions run freely"). */
export const READ_ONLY_TOOLS = new Set(["Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "TodoWrite", "NotebookRead"]);

const SYSTEM_APPEND = [
  "You are answering through Superclick, a small bubble at the user's pointer on their Mac.",
  "The request comes with context Superclick captured from the app they were in (window, selection, page text).",
  "Answer directly and concisely. If the user is likely to paste your answer back into that app, end with the text to paste and nothing after it.",
].join(" ");

/** A one-line description of a tool call, for the bubble. */
export function describeTool(tool: string, input: Record<string, unknown>): string {
  const s = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : undefined);
  const detail = s("command") ?? s("file_path") ?? s("path") ?? s("pattern") ?? s("url") ?? s("query") ?? s("description");
  if (!detail) return tool;
  const oneLine = detail.replace(/\s+/g, " ").trim();
  return `${tool} ${oneLine.length > 80 ? oneLine.slice(0, 79) + "…" : oneLine}`;
}

/** Turns a call into a queue we can iterate, so canUseTool can push events mid-turn. */
class EventQueue {
  private items: AgentEvent[] = [];
  private wake?: () => void;
  private closed = false;
  push(e: AgentEvent) {
    this.items.push(e);
    this.wake?.();
  }
  close() {
    this.closed = true;
    this.wake?.();
  }
  async *drain(): AsyncIterable<AgentEvent> {
    while (true) {
      while (this.items.length) yield this.items.shift()!;
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

export class ClaudeCodeSession implements AgentSession {
  readonly agent = "Claude Code";
  private sdkSessionId?: string;
  private pending = new Map<string, (a: Approval) => void>();
  private lastExchange = "";
  private busy = false;

  constructor(
    readonly cwd: string,
    private readonly queryFn: QueryFn = sdkQuery as unknown as QueryFn,
    private readonly approvalTimeoutMs = 10 * 60 * 1000,
  ) {}

  summary(): string {
    return this.lastExchange;
  }

  approve(approvalId: string, decision: Approval): boolean {
    const resolve = this.pending.get(approvalId);
    if (!resolve) return false;
    this.pending.delete(approvalId);
    resolve(decision);
    return true;
  }

  async *send(input: SendInput): AsyncIterable<AgentEvent> {
    if (this.busy) {
      yield { type: "error", message: "This session is still answering the last request." };
      return;
    }
    this.busy = true;
    const events = new EventQueue();
    const abort = new AbortController();
    input.signal?.addEventListener("abort", () => abort.abort());

    const canUseTool: CanUseTool = async (tool, toolInput, { signal }) => {
      if (READ_ONLY_TOOLS.has(tool)) return { behavior: "allow", updatedInput: toolInput };
      const approvalId = randomUUID();
      const summary = describeTool(tool, toolInput);
      events.push({ type: "approval", approvalId, tool, summary });
      const decision = await new Promise<Approval>((resolve) => {
        const timer = setTimeout(() => this.approve(approvalId, { allow: false, message: "No answer in time." }), this.approvalTimeoutMs);
        this.pending.set(approvalId, (a) => {
          clearTimeout(timer);
          resolve(a);
        });
        const cancel = () => this.approve(approvalId, { allow: false, message: "Cancelled." });
        signal.addEventListener("abort", cancel, { once: true });
        abort.signal.addEventListener("abort", cancel, { once: true });
      });
      if (decision.allow) return { behavior: "allow", updatedInput: toolInput };
      return {
        behavior: "deny",
        message: decision.message?.trim() ? `The user said: ${decision.message.trim()}` : "The user declined this.",
      };
    };

    const options: Options = {
      cwd: this.cwd,
      resume: this.sdkSessionId,
      includePartialMessages: true,
      permissionMode: "default",
      canUseTool,
      abortController: abort,
      systemPrompt: { type: "preset", preset: "claude_code", append: SYSTEM_APPEND },
    };

    const run = (async () => {
      let streamedAny = false;
      let needsBreak = false;
      try {
        for await (const m of this.queryFn({ prompt: input.prompt, options })) {
          if ("session_id" in m && typeof m.session_id === "string") this.sdkSessionId = m.session_id;
          if (m.type === "stream_event" && m.parent_tool_use_id === null) {
            const ev = m.event;
            if (ev.type === "content_block_start" && ev.content_block.type === "text" && streamedAny) needsBreak = true;
            if (ev.type === "content_block_delta" && ev.delta.type === "text_delta") {
              events.push({ type: "text", text: (needsBreak ? "\n\n" : "") + ev.delta.text });
              needsBreak = false;
              streamedAny = true;
            }
          } else if (m.type === "assistant" && m.parent_tool_use_id === null) {
            for (const block of m.message.content) {
              if (block.type === "tool_use" && READ_ONLY_TOOLS.has(block.name)) {
                events.push({ type: "tool", tool: block.name, summary: describeTool(block.name, block.input as Record<string, unknown>) });
              } else if (block.type === "text" && !streamedAny && block.text) {
                // No partial messages arrived (older CLI): send the whole block.
                events.push({ type: "text", text: block.text });
                streamedAny = true;
              }
            }
          } else if (m.type === "result") {
            if (m.subtype === "success" && !m.is_error) {
              this.lastExchange = `Q: ${input.prompt.split("\n")[0]!.slice(0, 200)}\nA: ${m.result.slice(0, 600)}`;
              events.push({ type: "done", text: m.result });
            } else {
              events.push({ type: "error", message: m.subtype === "success" ? m.result || "Claude Code reported an error." : `Claude Code stopped: ${m.subtype}` });
            }
          }
        }
      } catch (e) {
        events.push({ type: "error", message: abort.signal.aborted ? "Cancelled." : errorText(e) });
      } finally {
        for (const id of [...this.pending.keys()]) this.approve(id, { allow: false, message: "The turn ended." });
        this.busy = false;
        events.close();
      }
    })();

    yield* events.drain();
    await run;
  }
}

function errorText(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e);
  if (/login|auth|credential|api key/i.test(msg)) {
    return `Claude Code isn't signed in. Run \`claude\` in Terminal once and log in with your Claude account. (${msg})`;
  }
  return msg;
}

export class ClaudeCodeAdapter implements AgentAdapter {
  readonly name = "Claude Code";
  constructor(private readonly queryFn?: QueryFn) {}
  startSession({ cwd }: { cwd: string }): AgentSession {
    return new ClaudeCodeSession(cwd, this.queryFn);
  }
}
