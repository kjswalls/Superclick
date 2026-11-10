import { loadOrCreateToken, superclickHome } from "./auth.ts";
import { ClaudeCodeAdapter } from "./agents/claudeCode.ts";
import { QuickModel } from "./agents/quick.ts";
import { Coordinator } from "./coordinator.ts";
import { openDatabase } from "./db.ts";
import { ProjectRegistry } from "./projects.ts";
import { DEFAULT_PORT, VERSION, startDaemon } from "./server.ts";
import { SessionManager } from "./sessions.ts";

// Entry point: `bun run start`, or the compiled binary the app runs at login.
const port = Number(process.env.SUPERCLICK_PORT ?? DEFAULT_PORT);
const token = loadOrCreateToken();
const db = openDatabase();
const registry = new ProjectRegistry(db);
const quick = new QuickModel(registry.folder(registry.inbox));
const sessions = new SessionManager(new ClaudeCodeAdapter(), registry, db, quick);
const coordinator = new Coordinator(registry, db, quick, { summaries: (id) => sessions.summary(id) });
const { server } = startDaemon({ token, port, sessions, coordinator });
console.log(`[superclick] daemon ${VERSION} listening on ws://127.0.0.1:${server.port}/v1`);
console.log(`[superclick] data in ${superclickHome()}`);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    server.stop(true);
    db.close();
    process.exit(0);
  });
}
