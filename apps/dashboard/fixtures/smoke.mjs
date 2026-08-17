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

await server.close();
console.log(`\n${failures === 0 ? "all checks passed" : `${failures} FAILED`}`);
process.exit(failures === 0 ? 0 : 1);
