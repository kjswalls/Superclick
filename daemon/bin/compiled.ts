// Entry point for the daemon compiled into the app (scripts/build-app.sh runs
// `bun build --compile` on this file). It uses the Claude Code installed on
// the Mac rather than shipping its own copy (DECISIONS, 2026-11-12), and says
// so in Settings when there isn't one.
import { prepareLaunchdEnv } from "./launchd.ts";

process.env.SUPERCLICK_COMPILED = "1";
prepareLaunchdEnv();
await import("../src/index.ts");
