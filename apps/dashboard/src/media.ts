// =============================================================================
// The presentation vocabulary both media pages share
// -----------------------------------------------------------------------------
// A wire value is never rendered and a label is never parsed. That is the same
// split status.json makes between a stable `id` and disposable `message` prose,
// and it is why STATE_LABEL exists rather than a `.replace("_", " ")` at each
// call site.
// =============================================================================

import type { FileState, PlaybackSession, Tone, Transfer } from "@/types";
import * as links from "@/links";
import type { AppKey } from "@/links";

/** Three status colours and grey, per the brief. `queued` and `done` are grey
 *  because neither is a problem and neither is an achievement. */
export const STATE_TONE: Record<FileState, Tone> = {
  downloading: "ok",
  transcoding: "ok",
  importing: "ok",
  seeding: "ok",
  queued: "off",
  done: "off",
  stalled: "warn",
  no_subtitles: "warn",
  error: "fail",
};

export const STATE_LABEL: Record<FileState, string> = {
  downloading: "downloading",
  transcoding: "transcoding",
  importing: "importing",
  seeding: "seeding",
  queued: "queued",
  done: "done",
  stalled: "stalled",
  no_subtitles: "no subtitles",
  error: "error",
};

/**
 * Which of three groups a state belongs to. `live` is the only one whose
 * progress bar animates: motion has to carry data, so a bar that moves on a
 * finished row is decoration and a bar that moves on a stalled one is a lie.
 */
export function stateClass(state: FileState): "attention" | "live" | "steady" {
  if (state === "error" || state === "stalled" || state === "no_subtitles") return "attention";
  if (state === "downloading" || state === "transcoding" || state === "importing") return "live";
  return "steady";
}

/**
 * ATTENTION FIRST, THEN ACTIVITY - which is a deliberate deviation from the
 * design's footer text, and the footer is corrected to match rather than the
 * sort being bent to it.
 *
 * The design says "sorted by activity". On the real host that buries the one row
 * worth looking at: there are 145 completions in a week against a single
 * download, so an activity sort puts the error row somewhere past the fold. Both
 * built pages already sort worst-first and both say why - ServicesPage's is "a
 * rack sorted alphabetically buries the one row worth looking at somewhere in
 * the middle". A footer naming a sort the table does not perform would be worse
 * than either choice.
 *
 * It is also what makes the design's filter chips survive the real, lopsided
 * counts: `all` is dominated by `done` in population but not in what you see.
 */
const RANK: Record<FileState, number> = {
  error: 0,
  stalled: 1,
  no_subtitles: 2,
  downloading: 3,
  transcoding: 3,
  importing: 3,
  queued: 4,
  seeding: 5,
  done: 6,
};

export function sortRows(a: Transfer, b: Transfer): number {
  const byRank = RANK[a.state] - RANK[b.state];
  if (byRank !== 0) return byRank;
  // Within a rank: busiest first, then newest, then a stable tie-break so the
  // table does not shuffle between polls.
  const rate = (b.rate_bps ?? -1) - (a.rate_bps ?? -1);
  if (rate !== 0) return rate;
  const added = (b.added_at ?? "").localeCompare(a.added_at ?? "");
  if (added !== 0) return added;
  return a.id.localeCompare(b.id);
}

/**
 * DIRECT / HW TRANSCODE / SW TRANSCODE / TRANSCODE.
 *
 * Four labels for three colours: unmeasured hardware gets the same amber as a
 * measured software transcode but a shorter word, because "SW TRANSCODE" on a
 * host with a dedicated NVENC card is a real finding and must not be claimed on
 * the strength of a null. See PlaybackSession.hardware.
 */
export function badgeFor(session: PlaybackSession): { label: string; tone: Tone } {
  if (session.method === "transcode") {
    if (session.hardware === true) return { label: "HW TRANSCODE", tone: "warn" };
    if (session.hardware === false) return { label: "SW TRANSCODE", tone: "warn" };
    return { label: "TRANSCODE", tone: "warn" };
  }
  if (session.method === "directstream") return { label: "DIRECT STREAM", tone: "ok" };
  return { label: "DIRECT", tone: "ok" };
}

/**
 * "Pixel 8 Pro / Jellyfin for Android / 1920x800".
 *
 * NO LOCAL-VERSUS-REMOTE TOKEN, and the design's "remote via tailscale" is
 * dropped for a measured reason: every session reports Caddy's own net-media
 * address as its RemoteEndPoint, because everything reaches Jellyfin through the
 * proxy. A badge built on that field would be confidently wrong for every row,
 * which cannot be spotted from a dashboard. The collector does not even carry it.
 */
export function whoLine(session: PlaybackSession): string {
  const parts = [session.device, session.client].filter((p): p is string => !!p);
  if (session.width && session.height) parts.push(`${session.width}x${session.height}`);
  return parts.join(" / ");
}

export interface Action {
  label: string;
  href: string | null;
  title: string;
}

/**
 * The design's action chip, as a link. Every label is lowercase to match the
 * design's chips, and every one of them opens something rather than doing
 * something - see @/links for why that is structural.
 */
export function actionFor(row: Transfer): Action {
  const app = row.app as AppKey | null;
  if (app === "sonarr" && row.app_slug) {
    return { label: "sonarr", href: links.sonarrSeries(row.app_slug), title: "open this series in Sonarr" };
  }
  if (app === "radarr" && row.app_slug) {
    return { label: "radarr", href: links.radarrMovie(row.app_slug), title: "open this film in Radarr" };
  }
  if (app === "jellyfin" && row.item_id) {
    return { label: "watch", href: links.jellyfinItem(row.item_id), title: "open this item in Jellyfin" };
  }
  if (app === "qbittorrent") {
    return {
      label: "torrent",
      href: links.qbittorrent(),
      // Said out loud because the chip sits on a specific row and cannot reach it.
      title: "open qBittorrent - it has no per-torrent address, so this opens the client",
    };
  }
  if (app === "tdarr") {
    return { label: "tdarr", href: links.tdarr(), title: "open Tdarr" };
  }
  if (app) {
    return { label: app, href: links.appHome(app), title: `open ${app}` };
  }
  return { label: "-", href: null, title: "nothing here owns this row" };
}

/**
 * The media stack, for Home's service strip - ten containers rather than all
 * twenty-three. `app` is null where the container has no web interface to open.
 *
 * A SECOND HAND-MAINTAINED LIST, which CLAUDE.md calls the most driftable shape
 * this repository has a name for. It is checked against @/topology at startup in
 * dev, which is the `uncovered()` idea applied to this list: a container renamed
 * in stacks/ shows up as a console warning rather than as a chip that silently
 * stops appearing.
 */
export interface StripService {
  container: string;
  label: string;
  app: AppKey | null;
}

export const STRIP_SERVICES: readonly StripService[] = [
  { container: "jellyfin", label: "jellyfin", app: "jellyfin" },
  { container: "jellyseerr", label: "jellyseerr", app: "jellyseerr" },
  { container: "sonarr", label: "sonarr", app: "sonarr" },
  { container: "radarr", label: "radarr", app: "radarr" },
  { container: "prowlarr", label: "prowlarr", app: "prowlarr" },
  { container: "bazarr", label: "bazarr", app: "bazarr" },
  { container: "tdarr-server", label: "tdarr", app: "tdarr" },
  { container: "tdarr-node-01", label: "tdarr node", app: null },
  { container: "qbittorrent", label: "qbittorrent", app: "qbittorrent" },
  { container: "unpackerr", label: "unpackerr", app: null },
];
