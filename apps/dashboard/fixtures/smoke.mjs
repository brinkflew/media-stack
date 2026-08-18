// Drives the media page logic in node against the dev fixtures, because this
// environment has no browser. Not a test suite - there is none in this repo -
// but it exercises the real modules rather than asserting on types.
//
//   node fixtures/smoke.mjs
import { createServer } from "vite";

const server = await createServer({ server: { middlewareMode: true }, appType: "custom" });
const load = (p) => server.ssrLoadModule(p);

const { activityDocument, libraryDocument } = await load("/fixtures/media.ts");
const { sortRows, actionFor, badgeFor, whoLine, stateClass, STATE_LABEL, STATE_TONE } =
  await load("/src/media.ts");
const { posterHeight, posterUrl } = await load("/src/images.ts");
const { containerTone } = await load("/src/health.ts");
const fmt = await load("/src/format.ts");

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"}  ${name}${ok ? "" : `\n        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`}`);
};

const activity = activityDocument();
const library = libraryDocument();

// --- the merged, sorted row set, the way the store builds it -----------------
const merged = new Map();
for (const r of library.done) merged.set(r.id, r);
for (const r of library.attention) merged.set(r.id, r);
for (const r of activity.transfers) merged.set(r.id, r);
const rows = [...merged.values()].sort(sortRows);

console.log(`\n-- ${rows.length} rows, attention first --`);
for (const r of rows.slice(0, 8)) {
  const a = actionFor(r);
  console.log(
    `   ${STATE_LABEL[r.state].padEnd(13)} ${String(STATE_TONE[r.state]).padEnd(5)}` +
      ` ${stateClass(r.state).padEnd(9)} ${(a.label + (a.href ? "" : " (disabled)")).padEnd(20)} ${r.title.slice(0, 34)}`,
  );
}

check("first row is the most severe", rows[0].state, "error");
check("no completion above an error", rows.findIndex((r) => r.state === "done") > 0, true);
check("every state has a label", rows.every((r) => !!STATE_LABEL[r.state]), true);
check("every state has a tone", rows.every((r) => !!STATE_TONE[r.state]), true);
check("only live states animate", stateClass("stalled"), "attention");
check("done does not animate", stateClass("done"), "steady");

// --- null progress must not become 0 ----------------------------------------
const queued = rows.find((r) => r.state === "queued");
check("queued row keeps null progress", queued.progress, null);

// --- posters ----------------------------------------------------------------
check("22x32 thumb snaps to 80", posterHeight(32), 80);
check("76x110 card snaps to 240", posterHeight(110), 240);
check("150-wide grid cell snaps to 480", posterHeight(225), 480);
check(
  "tagged url is cacheable",
  posterUrl("Items/abc/Images/Primary", "t1", 240),
  "/api/images/Items/abc/Images/Primary?tag=t1&maxHeight=240",
);
check(
  "untagged url omits the tag",
  posterUrl("Items/abc/Images/Primary", null, 80),
  "/api/images/Items/abc/Images/Primary?maxHeight=80",
);

// --- sessions ---------------------------------------------------------------
console.log("\n-- sessions --");
for (const s of activity.sessions) {
  const b = badgeFor(s);
  console.log(`   ${b.label.padEnd(14)} ${b.tone.padEnd(5)} ${s.paused ? "paused " : "playing"}  ${whoLine(s)}`);
}
check("direct play badge", badgeFor(activity.sessions[0]).label, "DIRECT");
check("hw transcode badge", badgeFor(activity.sessions[1]).label, "HW TRANSCODE");
check("unmeasured hardware is not called software", badgeFor({ method: "transcode", hardware: null }).label, "TRANSCODE");
check("unmeasured hardware never reads healthy", badgeFor({ method: "transcode", hardware: null }).tone, "warn");
check("who line carries no local/remote token", /local|remote/i.test(whoLine(activity.sessions[0])), false);

// --- health: absent is not zero --------------------------------------------
check("no health check is grey", containerTone(true, undefined), { tone: "off", state: "running, unchecked" });
check("healthy is teal", containerTone(true, 0), { tone: "ok", state: "healthy" });
check("stopped is red", containerTone(false, undefined), { tone: "fail", state: "stopped" });

// --- format -----------------------------------------------------------------
check("elapsed keeps every field past an hour", fmt.elapsed(3661), "01:01:01");
check("elapsed of NaN is the dash", fmt.elapsed(Number.NaN), fmt.NO_DATA);
check("percent of 0 is not the dash", fmt.percent(0, 0), "0%");

// --- the contract that must never be optional -------------------------------
check("activity names every upstream", Object.keys(activity.sources).sort(), [
  "jellyfin",
  "qbittorrent",
  "radarr",
  "sonarr",
  "tdarr",
]);
check("library names every upstream", Object.keys(library.sources).length, 6);
check(
  "a pending request has no poster",
  library.requests.find((r) => r.status === "pending").poster,
  null,
);


// --- the network graph -------------------------------------------------------
// The topology and the edge list are compiled-in git data, so every claim below
// is checkable without a browser - which is the whole reason graph.ts holds no
// Vue and no DOM.
const T = await load("/src/topology.ts");
const NODE_NAMES = new Set(T.NODES.map((n) => n.name));
const P = await load("/src/paths.ts");
const G = await load("/src/graph.ts");

console.log(`\n-- ${P.PATHS.length} declared routes --`);

const impossible = P.PATHS.filter(
  (p) => P.edgeKind(p) === "segment" && P.segmentsFor(p).length === 0,
);
check("every declared route crosses a shared segment", impossible.map((p) => `${p.from}->${p.to}`), []);

const orphan = P.PATHS.filter(
  (p) => ![p.from, p.to].every((n) => P.isPseudo(n) || NODE_NAMES.has(n)),
);
check("every endpoint is a container or a terminal", orphan.map((p) => `${p.from}->${p.to}`), []);

// A terminal absorbs, so no chain may pass THROUGH one. Without this, the
// inbound and outbound ends of the world join up and the walk reports
// "duckdns -> wan -> caddy -> sonarr", which is two real routes spliced at a
// place no packet crosses.
const through = [];
for (const name of ["sonarr", "caddy", "prowlarr", "jellyfin"]) {
  for (const chain of P.tracePaths(name)) {
    for (let i = 1; i < chain.length - 1; i += 1) {
      if (P.isPseudo(chain[i])) through.push(chain.join(" -> "));
    }
  }
}
check("no route passes through a terminal", through, []);

const L = G.layout();
check("every box has a finite position", L.nodes.every((n) => Number.isFinite(n.x) && Number.isFinite(n.y)), true);
check("the hub spans more than one rail", (L.hub?.rails.length ?? 0) > 1, true);
check("no two boxes overlap", (() => {
  const ext = L.nodes.map((n) => ({ ...n, bot: n.y + n.h + (n.members.length ? n.members.length * 12 + 10 : 0) }));
  for (let i = 0; i < ext.length; i++)
    for (let j = i + 1; j < ext.length; j++) {
      const a = ext[i], b = ext[j];
      if (a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.bot && b.y < a.bot) return `${a.name}/${b.name}`;
    }
  return null;
})(), null);

// Rate to motion. Zero must be still: a link carrying a keepalive is idle, and
// animating it spends the reader's attention on nothing.
check("below the floor is still", G.intensity(512), 0);
check("absent is still", G.intensity(Number.NaN), 0);
check("the scale is logarithmic", G.intensity(1024 ** 2) > 0.5 && G.intensity(1024 ** 2) < 0.7, true);
check("the ceiling clamps", G.intensity(1024 ** 4), 1);
check("busier is faster", G.flowDuration(10e6) < G.flowDuration(10e3), true);


await server.close();
console.log(`\n${failures === 0 ? "all checks passed" : `${failures} FAILED`}`);

process.exit(failures === 0 ? 0 : 1);
