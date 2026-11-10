import { loadOrCreateToken, superclickHome } from "./auth.ts";
import { ClaudeCodeAdapter } from "./agents/claudeCode.ts";
import { DEFAULT_PORT, VERSION, startDaemon } from "./server.ts";
import { SessionManager } from "./sessions.ts";

// Entry point. From M2 this runs as a LaunchAgent inside the app bundle;
// for now, start it by hand with `bun run start`.
const port = Number(process.env.SUPERCLICK_PORT ?? DEFAULT_PORT);
const token = loadOrCreateToken();
const sessions = new SessionManager(new ClaudeCodeAdapter());
const { server } = startDaemon({ token, port, sessions });
console.log(`[superclick] daemon ${VERSION} listening on ws://127.0.0.1:${server.port}/v1`);
console.log(`[superclick] token in ${superclickHome()}/daemon.token`);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    server.stop(true);
    process.exit(0);
  });
}
