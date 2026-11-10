import { loadOrCreateToken, superclickHome } from "./auth.ts";
import { ClaudeCodeAdapter } from "./agents/claudeCode.ts";
import { QuickModel } from "./agents/quick.ts";
import { ContextService, RECENT_TOOL } from "./contextMcp.ts";
import { Coordinator } from "./coordinator.ts";
import { openDatabase } from "./db.ts";
import { Journal } from "./journal.ts";
import { ProjectRegistry } from "./projects.ts";
import { DEFAULT_PORT, VERSION, startDaemon } from "./server.ts";
import { RequestStore } from "./store.ts";
import { SessionManager } from "./sessions.ts";

// Entry point: `bun run start`, or the compiled binary the app runs at login.
const port = Number(process.env.SUPERCLICK_PORT ?? DEFAULT_PORT);
const token = loadOrCreateToken();
const db = openDatabase();
const registry = new ProjectRegistry(db);
const quick = new QuickModel(registry.folder(registry.inbox));
const store = new RequestStore();
const context = new ContextService(store);
const adapter = new ClaudeCodeAdapter(undefined, { mcpServers: (turn) => context.server(turn), alsoAllowed: [RECENT_TOOL] });
const sessions = new SessionManager(adapter, registry, db, quick);
const coordinator = new Coordinator(registry, db, quick, { summaries: (id) => sessions.summary(id) });
const journal = new Journal(db);
let started: ReturnType<typeof startDaemon>;
try {
  started = startDaemon({ token, port, store, sessions, coordinator, journal, context });
} catch (e) {
  // Another daemon (a `bun run start` in a Terminal, say) already has the port.
  // Exit cleanly, so launchd's KeepAlive doesn't restart this one every 10 seconds.
  const code = (e as { code?: string }).code;
  if (code === "EADDRINUSE" || String(e).includes("EADDRINUSE") || String(e).includes("in use")) {
    console.log(`[superclick] port ${port} is in use; another Superclick daemon is probably running. Exiting.`);
    db.close();
    process.exit(0);
  }
  throw e;
}
const { server } = started;
console.log(`[superclick] daemon ${VERSION} listening on ws://127.0.0.1:${server.port}/v1`);
console.log(`[superclick] data in ${superclickHome()}`);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    server.stop(true);
    db.close();
    process.exit(0);
  });
}
