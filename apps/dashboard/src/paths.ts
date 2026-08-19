// =============================================================================
// Who talks to whom, and over which segment
// -----------------------------------------------------------------------------
// topology.ts says which containers are ON which bridge. That is membership,
// not reachability, and it is not what anyone actually wants to know: the
// question a network page has to answer is "what is the path from the browser
// to this file on disk", which membership alone cannot draw.
//
// THIS FILE IS NOT IN topology.ts, AND THAT IS NOT A STYLE PREFERENCE.
// bin/lint-repo.sh derives the list of network segments with
//
//     re.findall(r'id:\s*"([^"]+)"', topo)
//
// over the WHOLE of topology.ts. Any object literal added there with an `id:`
// field is read as a tenth network segment and fails the lint - which is a
// booby trap rather than a check, so the edge list lives in its own module
// where no regex is aimed at it.
//
// WHAT THE LINT CAN AND CANNOT PROVE. bin/lint-repo.sh asserts that both
// endpoints of every edge exist and that they SHARE the named segment - so an
// edge that Options=isolate=true forbids cannot be declared here without
// failing the build. That is a real check and it is the important one.
//
// It proves the path is POSSIBLE. It cannot prove the path is USED, because
// half of these edges are configured inside an application's own database -
// sonarr's download client, prowlarr's FlareSolverr tag, bazarr's series list -
// which is gitignored runtime state that no linter can read. `source` marks
// which half an edge is in, so nobody mistakes the check for a stronger one
// than it is.
// =============================================================================

import { NODES, nodeByName } from "@/topology";

/** Endpoints that are not containers. A path has to be able to start and end
 *  somewhere real, and "the internet" is where most of them do. */
// TWO terminals, not one, and collapsing them into a single "wan" node is a
// modelling bug rather than a simplification. Inbound and outbound are
// different ends of the world: with one shared node, `duckdns -> wan` and
// `wan -> caddy` join up, and a path walk cheerfully reports
// "duckdns -> wan -> caddy -> sonarr" - a route that does not exist, assembled
// out of two that do.
export const PSEUDO_NODES: Record<string, string> = {
  wan: "a browser, on the LAN or beyond it - inbound only",
  internet: "everything outside this host - outbound only",
};

export interface Path {
  from: string;
  to: string;
  /** One line. Why this edge exists, not what the protocol is. */
  why: string;
  /**
   * "git"     - declared in stacks/, apps/caddy/Caddyfile or an apps/ config,
   *             so it is reviewable and could in principle be generated.
   * "runtime" - configured inside an application's own database. Invisible to
   *             git grep, restored from a backup rather than from this repo,
   *             and the reason the lint validates rather than derives.
   */
  source: "git" | "runtime";
}

export const PATHS: Path[] = [
  // --- ingress: the Caddyfile's site blocks --------------------------------
  { from: "wan", to: "caddy", source: "git",
    why: "every request arrives on 80 or 443, the only published ports here" },
  { from: "caddy", to: "jellyfin", source: "git",
    why: "watch.{$DOMAIN}, outside sign-on - a TV has no browser for a passkey" },
  { from: "caddy", to: "jellyseerr", source: "git",
    why: "request.{$DOMAIN}, outside sign-on for the same reason" },
  { from: "caddy", to: "ntfy", source: "git",
    why: "ntfy.{$DOMAIN}, outside sign-on; it authenticates its own users" },
  { from: "caddy", to: "pocket-id", source: "git",
    why: "id.{$DOMAIN}, the passkey provider the browser is redirected to" },
  { from: "caddy", to: "tinyauth", source: "git",
    why: "auth.{$DOMAIN}, and the forward_auth call on every protected block" },
  { from: "caddy", to: "sonarr", source: "git",
    why: "sonarr.{$DOMAIN}, behind sign-on" },
  { from: "caddy", to: "radarr", source: "git",
    why: "radarr.{$DOMAIN}, behind sign-on" },
  { from: "caddy", to: "prowlarr", source: "git",
    why: "prowlarr.{$DOMAIN}, behind sign-on" },
  { from: "caddy", to: "bazarr", source: "git",
    why: "bazarr.{$DOMAIN}, behind sign-on" },
  { from: "caddy", to: "tdarr-server", source: "git",
    why: "tdarr.{$DOMAIN}, behind sign-on" },
  { from: "caddy", to: "torrent", source: "git",
    why: "torrent.{$DOMAIN} and fakerr.{$DOMAIN} both address the POD, not gluetun" },
  { from: "caddy", to: "prometheus", source: "git",
    why: "metrics.{$DOMAIN}, and /api/prom on home.{$DOMAIN}" },
  { from: "caddy", to: "alertmanager", source: "git",
    why: "/api/alerts on home.{$DOMAIN}, GET and HEAD only" },
  { from: "caddy", to: "dashboard", source: "git",
    why: "home.{$DOMAIN}: this page, and status.json as a file" },
  { from: "caddy", to: "windmill-server", source: "git",
    why: "agents.{$DOMAIN}, behind sign-on - the only route into the control plane" },

  // --- declared in stacks/, as an Environment= hostname ---------------------
  { from: "tinyauth", to: "pocket-id", source: "git",
    why: "token and userinfo over the shared segment, never the public name" },
  { from: "unpackerr", to: "sonarr", source: "git",
    why: "polls the queue API to learn what to extract; touches only the disk" },
  { from: "unpackerr", to: "radarr", source: "git",
    why: "the same poll, for films" },
  { from: "tdarr-node-01", to: "tdarr-server", source: "git",
    why: "serverIP=tdarr-server; the node asks for work" },
  { from: "gluetun", to: "qbittorrent", source: "git",
    why: "pushes the forwarded port on every reconnect, over the shared loopback" },

  // --- declared in an apps/ config file ------------------------------------
  { from: "prometheus", to: "node-exporter", source: "git",
    why: "the only scrape target besides itself; the textfile drop arrives here" },
  { from: "prometheus", to: "alertmanager", source: "git",
    why: "where a firing rule goes" },
  { from: "alertmanager", to: "ntfy-alertmanager", source: "git",
    why: "the webhook, with basic auth" },
  { from: "ntfy-alertmanager", to: "ntfy", source: "git",
    why: "publishes the notification to the topic the phone subscribes to" },
  { from: "ntfy-alertmanager", to: "alertmanager", source: "git",
    why: "reads alerts back to render them" },

  // --- runtime only: inside an application's own database ------------------
  { from: "sonarr", to: "prowlarr", source: "runtime",
    why: "indexer sync; prowlarr pushes every indexer to every application" },
  { from: "radarr", to: "prowlarr", source: "runtime",
    why: "the same sync, for films" },
  { from: "sonarr", to: "torrent", source: "runtime",
    why: "download client. The host is 'torrent' - the POD - not qbittorrent" },
  { from: "radarr", to: "torrent", source: "runtime",
    why: "the same client, addressed the same way" },
  { from: "prowlarr", to: "flaresolverr", source: "runtime",
    why: "challenge solving; the only edge into net-solver, and the point of it" },
  { from: "jellyseerr", to: "jellyfin", source: "runtime",
    why: "reads library state to know what is already available" },
  { from: "jellyseerr", to: "sonarr", source: "runtime",
    why: "files an approved series request" },
  { from: "jellyseerr", to: "radarr", source: "runtime",
    why: "files an approved film request" },
  { from: "bazarr", to: "sonarr", source: "runtime",
    why: "reads the series library to know what wants subtitles" },
  { from: "bazarr", to: "radarr", source: "runtime",
    why: "the same, for films" },

  // --- egress: where a path ends -------------------------------------------
  { from: "torrent", to: "internet", source: "git",
    why: "every peer connection leaves through the tunnel in gluetun's namespace, or not at all. Measured as network=tunnel" },
  { from: "duckdns", to: "internet", source: "git",
    why: "publishes this host's WAN address; the one segment with a single member" },
  { from: "flaresolverr", to: "internet", source: "runtime",
    why: "fetches attacker-controlled indexer pages - measured as the largest single talker to the outside" },
];

// -----------------------------------------------------------------------------
// The segment an edge crosses is DERIVED, never declared
// -----------------------------------------------------------------------------
// Writing `via: "net-arr"` on each edge was the obvious design and it is wrong,
// for a reason that only shows up once you check: THE INTERSECTION IS OFTEN
// LARGER THAN ONE. caddy and sonarr share net-arr AND net-download; caddy and
// jellyseerr share net-arr AND net-media. Which address podman's DNS resolves
// at connect time is declared nowhere and is not observable from here - so a
// hand-written `via` is a claim nothing supports, and a second copy of
// something topology.ts already holds.
//
// Deriving it instead gives a chain that cannot drift:
//
//     stacks/  --lint-->  topology.ts  --derived-->  paths.ts
//
// and it makes the ambiguity itself a value the drawing can render, rather
// than a detail a declaration quietly papers over.

export type EdgeKind = "segment" | "pod" | "terminal";

export function edgeKind(p: Path): EdgeKind {
  if (isPseudo(p.from) || isPseudo(p.to)) return "terminal";
  const a = nodeByName(p.from);
  const b = nodeByName(p.to);
  // Two containers in the same pod share a network NAMESPACE, not a network,
  // so their `networks` arrays are both empty and intersect to nothing. That
  // is not an isolation violation - it is the tightest coupling here.
  if (a?.pod && b?.pod && a.pod === b.pod) return "pod";
  return "segment";
}

/**
 * Every segment both endpoints are on.
 *
 * Length 0 on a "segment" edge means the two cannot reach each other at all -
 * every bridge carries Options=isolate=true - so either the edge is fiction or
 * topology.ts is wrong. Length > 1 means the path is real but which bridge
 * carries it is not knowable from here, which the graph renders as ambiguity
 * rather than picking one.
 */
export function segmentsFor(p: Path): string[] {
  if (edgeKind(p) !== "segment") return [];
  const a = nodeByName(p.from)?.networks ?? [];
  const b = new Set(nodeByName(p.to)?.networks ?? []);
  return a.filter((n) => b.has(n));
}

/** Members of a segment, counted once. Two members is what makes a spoke an
 *  edge; more than two is what stops it being one. */
export function memberCount(network: string): number {
  return NODES.filter((n) => n.networks.includes(network)).length;
}

export function isPseudo(node: string): boolean {
  return node in PSEUDO_NODES;
}

/** Every edge touching a node, in either direction. */
export function pathsTouching(node: string): Path[] {
  return PATHS.filter((p) => p.from === node || p.to === node);
}

/**
 * Every route through `node`, walked outward in both directions.
 *
 * Hovering sonarr yields the whole chain a request takes to reach a file:
 * wan -> caddy -> sonarr -> torrent -> vpn.
 *
 * THE EDGE LIST IS NOT ACYCLIC AND WILL NOT STAY SO. prowlarr and the *arr
 * apps genuinely point at each other, so the visited set - not a depth limit -
 * is what makes this terminate. A depth limit would silently truncate a real
 * chain instead.
 */
export function tracePaths(node: string): string[][] {
  const heads: string[][] = [];
  const grow = (chain: string[], forward: boolean, out: string[][]): void => {
    const head = forward ? chain[chain.length - 1] : chain[0];
    // A TERMINAL ABSORBS. Walking THROUGH the outside world would splice two
    // unrelated routes together at their far ends and report the join as a
    // path - the same error as sharing one node between inbound and outbound,
    // arriving by a different door.
    const next = isPseudo(head)
      ? []
      : PATHS.filter((p) => (forward ? p.from === head : p.to === head))
          .map((p) => (forward ? p.to : p.from))
          .filter((n) => !chain.includes(n));
    if (!next.length) {
      out.push(chain);
      return;
    }
    for (const n of next) grow(forward ? [...chain, n] : [n, ...chain], forward, out);
  };

  grow([node], false, heads);
  const full: string[][] = [];
  for (const back of heads) grow(back, true, full);
  return full;
}
