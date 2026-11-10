// Entry point for the daemon compiled into the app (scripts/build-app.sh runs
// `bun build --compile` on this file). A compiled binary can't find the SDK's
// bundled Claude Code, so it's embedded here and extracted to a real path
// (see the SDK README, "Compiled binaries").
import binPath from "@anthropic-ai/claude-agent-sdk-darwin-x64/claude" with { type: "file" };
import { extractFromBunfs } from "@anthropic-ai/claude-agent-sdk/extract";

process.env.SUPERCLICK_CLAUDE_PATH ??= extractFromBunfs(binPath);
await import("../src/index.ts");
