// =============================================================================
// The synthetic media state
// -----------------------------------------------------------------------------
// Deliberately unhealthy, like the rest of the fixtures. A state where everything
// is fine exercises the layouts that need the least design work; the interesting
// ones are a stalled torrent, an import that failed and said why, a transcode
// mid-flight, and three posters that do not exist.
//
// TYPED AGAINST src/types.ts ON PURPOSE. tsconfig.node.json includes that file,
// so `npm run build` fails when a fixture drifts from the contract the collector
// writes - which is the uncovered() idea expressed through the type system, at no
// cost. If bin/collect-metrics.py changes a field, this file stops compiling.
//
// The switches below are environment variables; see the block above them.

// =============================================================================

import { MISSING_POSTERS } from "./images";
import type { ActivityDocument, LibraryDocument, RequestItem, Transfer } from "../src/types";

// FOUR SWITCHES, EACH READABLE FROM THE ENVIRONMENT. They are environment
// variables rather than constants to edit because the states they select are
// mutually exclusive with rendering the panel at all - you cannot have a fresh
// card and a frozen one on screen together - and editing a file to see one of
// them means a diff you then have to remember to revert. See README.md.
//
//   HS_FIX_PLAYBACK_AGE=40   the frozen card: extrapolation stops, the bar greys
//   HS_FIX_PLAYBACK_AGE=500  every stale path: dimmed cards, "no rows as of Nm"
//   HS_FIX_EMPTY=1           nothing playing, nothing in flight - the COMMON
//                            production state, and the one that must read as
//                            finished rather than broken
//   HS_FIX_BROKEN=jellyseerr the "absent, not zero" path for one upstream
const num = (key: string, fallback: number): number => {
  const raw = process.env[key];
  const n = raw === undefined ? Number.NaN : Number(raw);
  return Number.isFinite(n) ? n : fallback;
};

/** Age of activity.json. Under 30 keeps the extrapolation running. */
const PLAYBACK_AGE_S = num("HS_FIX_PLAYBACK_AGE", 8);

/** Age of library.json. Its threshold is 1200s. */
const LIBRARY_AGE_S = num("HS_FIX_LIBRARY_AGE", 360);

const BROKEN_SOURCE: string | null = process.env.HS_FIX_BROKEN ?? null;

/** Everything empty, which is what a healthy idle host actually looks like. */
const EMPTY = process.env.HS_FIX_EMPTY === "1";

function unless<T>(rows: T[]): T[] {
  return EMPTY ? [] : rows;
}

function iso(offsetSeconds: number): string {
  return new Date(Date.now() - offsetSeconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function sources(names: string[]): Record<string, { ok: boolean; at: string | null; error: string | null }> {
  const out: Record<string, { ok: boolean; at: string | null; error: string | null }> = {};
  for (const name of names) {
    const ok = name !== BROKEN_SOURCE;
    out[name] = { ok, at: ok ? iso(2) : null, error: ok ? null : "did not answer" };
  }
  return out;
}

const POSTER = (n: number) => `Items/aaaa${String(n).padStart(28, "0")}/Images/Primary`;

/** A row with every nullable field spelled out, so a missing one is a type error
 *  rather than an undefined at run time. */
function row(over: Partial<Transfer> & Pick<Transfer, "id" | "title" | "state">): Transfer {
  return {
    sub: null,
    kind: null,
    progress: null,
    size: null,
    rate_bps: null,
    rate_note: null,
    note: null,
    source: "radarr",
    quality: null,
    poster: null,
    poster_tag: null,
    app: null,
    app_slug: null,
    path: null,
    ...over,
  };
}

export function activityDocument(): ActivityDocument {
  return {
    schema: 1,
    generated_at: iso(PLAYBACK_AGE_S),
    sessions: unless([
      {
        id: "s1",
        item_id: "aaaa0000000000000000000000000001",
        title: "The Demon in the Snow",
        series: "Fallout",
        sub: "S02E04",
        kind: "series",
        user: "avanserv",
        client: "Jellyfin Web",
        device: "Chrome",
        method: "directplay",
        hardware: null,
        paused: false,
        position_s: 1782,
        runtime_s: 2923,
        width: 1920,
        height: 800,
        poster: POSTER(1),
        poster_tag: "tag1",
      },
      {
        // THE UNVERIFIED BRANCH. Nothing was transcoding when this was written,
        // so the shape of Jellyfin's TranscodingInfo is an assumption and so is
        // `hardware: true`. Confirm by forcing a browser transcode and re-polling
        // /Sessions before trusting the HW/SW distinction on screen.
        id: "s2",
        item_id: "aaaa0000000000000000000000000002",
        title: "Dune: Part Two",
        series: null,
        sub: "2024",
        kind: "movie",
        user: "avanserv",
        client: "Jellyfin for Android",
        device: "Pixel 8 Pro",
        method: "transcode",
        hardware: true,
        paused: true,
        position_s: 4210,
        runtime_s: 9960,
        width: 1920,
        height: 1080,
        poster: POSTER(2),
        poster_tag: "tag2",
      },
    ]),
    transfers: unless([
      row({
        id: "radarr:queue:1",
        title: "Kaamelott: The First Chapter",
        sub: "2021",
        kind: "movie",
        state: "downloading",
        progress: 0.5128,
        size: 32_025_793_760,
        rate_bps: 14_900_000,
        rate_note: "07:35:14",
        source: "radarr",
        quality: "Remux-1080p",
        app: "radarr",
        app_slug: "577242",
      }),
      row({
        id: "tdarr:1",
        title: "Grey Signal - S04E09",
        kind: "series",
        state: "transcoding",
        progress: 0.41,
        rate_note: "38 fps",
        note: "TdarrNode01",
        source: "tdarr",
        app: "tdarr",
      }),
      row({
        id: "sonarr:queue:2",
        title: "Harbour Notes",
        sub: "S01E02",
        kind: "series",
        state: "error",
        progress: 1,
        size: 3_800_000_000,
        note: "no series folder match",
        source: "sonarr",
        quality: "1080p WEB-DL",
        app: "sonarr",
        app_slug: "harbour-notes",
      }),
      row({
        id: "qbt:stalled",
        title: "The Long Field (2022)",
        kind: "movie",
        state: "stalled",
        progress: 0.62,
        size: 9_100_000_000,
        rate_bps: 0,
        rate_note: "no peers for 42m",
        source: "qbittorrent",
        app: "qbittorrent",
      }),
      row({
        id: "qbt:missing",
        title: "Harry.Potter.and.the.Philosophers.Stone.2001.MULTi.1080p",
        kind: "movie",
        state: "error",
        progress: 0,
        size: 18_400_000_000,
        rate_bps: 0,
        rate_note: "ratio 0.00",
        note: "files missing on disk",
        source: "qbittorrent",
        app: "qbittorrent",
      }),
      ...[0.66, 0.12, 1.0].map((ratio, i) =>
        row({
          id: `qbt:seed${i}`,
          title: ["Princess Mononoke (1997)", "Arcane S01", "Fallout S02"][i],
          kind: i === 0 ? "movie" : "series",
          state: "seeding",
          progress: 1,
          size: 12_000_000_000 + i * 3_000_000_000,
          rate_bps: i === 1 ? 44_443 : 0,
          rate_note: `ratio ${ratio.toFixed(2)}`,
          source: "qbittorrent",
          app: "qbittorrent",
        }),
      ),
    ]),
    sources: sources(["jellyfin", "sonarr", "radarr", "tdarr", "qbittorrent"]),
  };
}

/** Enough completions to exercise the tail and the sort, without 145 of them. */
const DONE: Transfer[] = Array.from({ length: 24 }, (_, i) =>
  row({
    id: `jf:done${i}`,
    item_id: `aaaa${String(i + 10).padStart(28, "0")}`,
    title: `Dust and Iron ${2000 + i}`,
    sub: String(2000 + i),
    kind: i % 3 === 0 ? "series" : "movie",
    state: "done",
    progress: 1,
    source: "jellyfin",
    // One of these is deliberately absent from the fixture image server, so the
    // fallback tile is on screen next to real ones.
    poster: i === 4 ? MISSING_POSTERS[0] : POSTER(i + 10),
    poster_tag: i === 4 ? null : `tag${i + 10}`,
    app: "jellyfin",
    added_at: iso(3600 * (i + 1)),
  }),
);

const REQUESTS: RequestItem[] = [
  {
    id: "jellyseerr:537",
    title: "Camp Rock 3",
    year: "2026",
    kind: "movie",
    status: "available",
    status_code: 2,
    media_status_code: 5,
    requested_by: "Brinkflew",
    requested_at: iso(7200),
    poster: POSTER(30),
    poster_tag: "tag30",
    jellyfin_id: "aaaa0000000000000000000000000030",
  },
  {
    // THE NORMAL CASE FOR THIS PANEL: pending, so there is no Jellyfin item and
    // therefore no poster anywhere. The placeholder is a designed state.
    id: "jellyseerr:538",
    title: "Northern Lines",
    year: "2026",
    kind: "series",
    status: "pending",
    status_code: 1,
    media_status_code: 2,
    requested_by: "Brinkflew",
    requested_at: iso(86400),
    poster: null,
    poster_tag: null,
    jellyfin_id: null,
  },
  {
    id: "jellyseerr:539",
    title: "Cold Harbour",
    year: "2024",
    kind: "movie",
    status: "processing",
    status_code: 2,
    media_status_code: 3,
    requested_by: "Brinkflew",
    requested_at: iso(259200),
    poster: MISSING_POSTERS[1],
    poster_tag: null,
    jellyfin_id: "aaaa0000000000000000000000000031",
  },
];

export function libraryDocument(): LibraryDocument {
  return {
    schema: 1,
    generated_at: iso(LIBRARY_AGE_S),
    recently_added: unless(DONE.slice(0, 12)),
    recently_added_total: EMPTY ? 0 : 145,
    done: unless(DONE),
    attention: unless([
      row({
        id: "queued:/mnt/media/library/queued/movies/Quiet Fields (2023)",
        title: "Quiet Fields (2023)",
        kind: "movie",
        state: "stalled",
        note: "Tdarr recorded a finished verdict and the file is still here",
        source: "tdarr",
        app: "tdarr",
        path: "/mnt/media/library/queued/movies/Quiet Fields (2023)",
      }),
      row({
        id: "queued:/mnt/media/library/queued/series/Slow Water",
        title: "Slow Water S01",
        kind: "series",
        state: "queued",
        source: "filesystem",
        path: "/mnt/media/library/queued/series/Slow Water",
      }),
    ]),
    requests: unless(REQUESTS),
    request_counts: EMPTY
      ? { total: 0, pending: 0, approved: 0, processing: 0, available: 0, declined: 0 }
      : { total: 104, pending: 1, approved: 25, processing: 25, available: 53, declined: 0 },
    totals: { no_subtitle_episodes: 543, no_subtitle_movies: 1 },
    sources: sources(["jellyfin", "jellyseerr", "radarr", "sonarr", "bazarr", "filesystem"]),
  };
}
