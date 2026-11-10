// A context bundle shaped like the one the Mac app sends.
export const bundle = (over: Record<string, unknown> = {}) => ({
  id: "cap-1",
  capturedAt: "2026-11-10T18:00:00Z",
  app: { name: "Safari", bundleID: "com.apple.Safari", pid: 42 },
  url: "https://example.com/article",
  selection: "actors isolate state",
  page: { text: "Intro. actors isolate state. End.", headings: [{ level: 1, text: "Intro" }], method: "textMarkers", wordCount: 5 },
  redactions: { "GitHub token": 1 },
  timings: { visible: 40 },
  ...over,
});
