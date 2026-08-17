// =============================================================================
// Every deep link out of this dashboard, in one file
// -----------------------------------------------------------------------------
// THIS IS WHERE THE READ-ONLY DECISION SHOWS UP IN THE UI. The design gives both
// new pages write affordances - Terminate a stream, Approve a request, Fix path,
// Force recheck, Retry, Start now, Scan library - and no container here can have
// any of them: `container_t -> unconfined_t : unix_stream_socket connectto` is
// DENY, and that is not fixable by relabelling. So each of those becomes a link
// that opens the owning application, which is read-only, keeps the design's
// layout slot, and is what its own fallback chip ("Open") already did.
//
// NO BUILD-TIME VARIABLE AND NO .env ENTRY. Every target already has its own
// Caddy site block as `<name>.{$DOMAIN}`, and this page is served from
// `home.{$DOMAIN}` - so the sibling hostname is the current one with its first
// label replaced. {$DOMAIN} never enters the bundle.
//
// AN APP KEY IS NOT A CONTAINER NAME. jellyfin answers at `watch`, jellyseerr at
// `request`, qbittorrent at `torrent`, tdarr-server at `tdarr`. That mapping
// exists here and nowhere else.
//
// FOUR OF THESE HOSTS SIT BEHIND THE SAME SIGN-ON AS THIS PAGE and two do not:
// `watch` and `request` authenticate their own users, because a TV and a phone
// have no browser to complete a passkey prompt in. So some chips open straight
// in and some may show a login first. Not a bug, and surprising if unrecorded.
// =============================================================================

export type AppKey =
  | "jellyfin"
  | "jellyseerr"
  | "sonarr"
  | "radarr"
  | "prowlarr"
  | "bazarr"
  | "tdarr"
  | "qbittorrent";

/** The first label of each application's hostname. */
const SUBDOMAIN: Record<AppKey, string> = {
  jellyfin: "watch",
  jellyseerr: "request",
  sonarr: "sonarr",
  radarr: "radarr",
  prowlarr: "prowlarr",
  bazarr: "bazarr",
  tdarr: "tdarr",
  qbittorrent: "torrent",
};

/**
 * The origin of an application, or null when there is no sibling to reach.
 *
 * null is the `npm run dev` case: the host is `localhost:5173`, there is no
 * `sonarr.localhost`, and a chip that silently pointed at one would be worse
 * than a chip that says it cannot go there - so ChipLink renders a disabled box
 * instead. It is also the honest answer for any preview host or bare IP.
 */
export function appBase(app: AppKey): string | null {
  // Guarded rather than assumed: this module is pure apart from this one read,
  // and throwing outside a DOM would make it unusable from any other context -
  // including a node harness that exercises the link vocabulary.
  if (typeof window === "undefined") return null;
  const labels = window.location.hostname.split(".");
  // Needs at least name.domain.tld, and the first label must be the one this
  // page is actually served from. Anything else and the sibling is a guess.
  if (labels.length < 3 || labels[0] !== "home") return null;
  labels[0] = SUBDOMAIN[app];
  return `${window.location.protocol}//${labels.join(".")}`;
}

function link(app: AppKey, path: string): string | null {
  const base = appBase(app);
  return base === null ? null : base + path;
}

/** Jellyfin's own item page. Note this CANNOT terminate a session, which is why
 *  the now-playing chip says "open" rather than the design's "terminate". */
export function jellyfinItem(itemId: string): string | null {
  return link("jellyfin", `/web/#/details?id=${encodeURIComponent(itemId)}`);
}

export function sonarrSeries(slug: string): string | null {
  return link("sonarr", `/series/${encodeURIComponent(slug)}`);
}

export function radarrMovie(slug: string): string | null {
  return link("radarr", `/movie/${encodeURIComponent(slug)}`);
}

export function jellyseerrRequests(): string | null {
  return link("jellyseerr", "/requests");
}

/** qBittorrent has no per-torrent route, so this opens the client. The chip's
 *  title says so rather than implying it will land on the row. */
export function qbittorrent(): string | null {
  return link("qbittorrent", "/");
}

export function tdarr(): string | null {
  return link("tdarr", "/");
}

export function bazarr(): string | null {
  return link("bazarr", "/");
}

export function appHome(app: AppKey): string | null {
  return link(app, "/");
}
