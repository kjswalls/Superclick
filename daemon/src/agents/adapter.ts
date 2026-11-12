import type { ContextBundle } from "../protocol.ts";

// The adapter interface from SPEC.md ("Instructions for the Claude Code build
// agent", item 4): start_session, send(message, context), stream_events,
// approve(request_id), summary(). Claude Code is the first implementation;
// OpenClaw must fit later without changes to the coordinator.

export type AgentEvent =
  /** A piece of the reply as it streams. */
  | { type: "text"; text: string }
  /** The agent used a tool (shown as a quiet line in the bubble). */
  | { type: "tool"; tool: string; summary: string }
  /** The agent wants to do something that needs the user's OK. */
  | { type: "approval"; approvalId: string; tool: string; summary: string; detail: string }
  /** An approval ended without the user's answer (timed out, cancelled, or the turn ended). */
  | { type: "approval.closed"; approvalId: string; reason: string }
  /** The agent was allowed to write this file (for the catch-up cards' "what changed"). */
  | { type: "changed"; path: string }
  /** The turn finished. `text` is the final answer, the part "Paste here" pastes. */
  | { type: "done"; text: string }
  | { type: "error"; message: string };

export interface Approval {
  allow: boolean;
  /** What the user typed instead (DECISIONS: every choice also takes typed input). */
  message?: string;
}

export interface SendInput {
  /** The request with its context rendered as Markdown (by the app's PromptText). */
  prompt: string;
  context?: ContextBundle;
  signal?: AbortSignal;
}

export interface AgentSession {
  readonly agent: string;
  readonly cwd: string;
  /** stream_events: the events of one turn, ending with done or error. */
  send(input: SendInput): AsyncIterable<AgentEvent>;
  approve(approvalId: string, decision: Approval): boolean;
  readonly isBusy: boolean;
  /** Stops the running turn and any queued ones. */
  cancel(): void;
  /** A running summary the coordinator can read (M3 routing, M4 catch-up cards). */
  summary(): string;
}

export interface StartOptions {
  cwd: string;
  /** The agent's own id for a session to pick up again, saved from an earlier run. */
  resumeId?: string;
  onSessionId?: (id: string) => void;
  /** The project this session belongs to, so per-turn tools can stay inside it. */
  projectId?: string;
}

export interface AgentAdapter {
  readonly name: string;
  startSession(opts: StartOptions): AgentSession;
}
