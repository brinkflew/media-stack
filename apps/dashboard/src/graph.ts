// =============================================================================
// The topology, as coordinates
// -----------------------------------------------------------------------------
// Pure arithmetic, no Vue and no DOM, the same shape as src/charts.ts - and for
// the same reason: this is the part that has to be checkable in node, and
// fixtures/smoke.mjs checks it.
//
// LAYOUT IS COMPUTED, NOT HAND-PLACED. That sentence is inherited verbatim from
// the component this replaces, and it is the constraint the whole file exists
// to keep: "a diagram that is expensive to update is a diagram that stops being
// true". Adding a network is one entry in topology.ts and adding a service is
// one entry plus its edges - never a coordinate.
//
// THE DRAWING IS BIPARTITE BECAUSE THE MEASUREMENT IS. The collector produces
// (container, network) pairs: a container's bytes on a segment. It cannot
// produce container-to-container, because per-flow accounting is unavailable on
// this host - conntrack is unreadable and nsenter is EPERM. So a segment is a
// vertex here, drawn as a rail, and the only line carrying a measured rate is
// the SPOKE from a container to a rail. A point-to-point arrow with a number on
// it would be a claim nothing supports.
//
// Declared routes from paths.ts are drawn in a different visual language, on
// demand, and never animate. Reachability comes from git; motion comes from
// measurement; the two must not be able to borrow each other's credibility.
// =============================================================================

import { NETWORKS, NODES, type Node } from "@/topology";
import { PATHS, isPseudo } from "@/paths";

export const NODE_W = 150;
export const NODE_H = 36;
export const COL_GAP = 44;
/** 84, not 76, and the extra 8px is the pod. The torrent box carries three
 *  nested members below it (12px each plus padding), which reached 2px into the
 *  net-media rail underneath and drew a box overlapping jellyfin. Rail spacing
 *  therefore has to clear the TALLEST node, not the standard one. */
export const RAIL_GAP = 84;
/** The rail names live here and NOTHING is placed in it. The first attempt put
 *  the hub at x=8 and the labels at x=8, so every label but one was hidden
 *  behind a box - a legend the drawing covered up. */
export const LABEL_GUTTER = 116;
/** The hub gets a column of its own, immediately after the labels. */
export const HUB_X = LABEL_GUTTER;
export const LEFT_GUTTER = HUB_X + NODE_W + COL_GAP;
export const TOP_PAD = 30;

export interface PlacedNode {
  name: string;
  role: string;
  x: number;
  y: number;
  w: number;
  h: number;
  /** The rail this box sits on. */
  rail: string;
  /** Every rail it is on, including `rail`. One spoke is drawn per entry. */
  rails: string[];
  rank: number;
  pod?: string;
  members: Node[];
}

export interface PlacedRail {
  id: string;
  purpose: string;
  y: number;
  members: number;
  /** No container on this rail has a route to Caddy. */
  detached: boolean;
}

export interface Layout {
  width: number;
  height: number;
  rails: PlacedRail[];
  nodes: PlacedNode[];
  hub: PlacedNode | undefined;
}

const HUB = "caddy";

/**
 * Longest-path rank, not BFS-shortest, and the difference is visible.
 *
 * Shortest-path puts `torrent` at rank 2, because Caddy proxies
 * torrent.{$DOMAIN} - and then `sonarr -> torrent`, which wants rank 3, points
 * backwards. Longest-path guarantees rank(to) > rank(from) for every edge in an
 * acyclic graph, which is what lets direction be read off the drawing without
 * an arrowhead on every line.
 *
 * THE EDGE LIST IS NOT ACYCLIC AND WILL NOT STAY SO. prowlarr and the *arr apps
 * genuinely point at each other. A naive longest-path walk does not terminate
 * on a cycle, so the recursion carries its own stack and treats a revisit as a
 * back-edge: the node keeps the rank it already has and the walk stops. That is
 * a real answer rather than a crash, and it degrades to "slightly flatter" as
 * cycles are added rather than to "blank page".
 */
export function rankNodes(): Map<string, number> {
  const out = new Map<string, number>();
  const outgoing = new Map<string, string[]>();
  for (const p of PATHS) {
    if (isPseudo(p.from) || isPseudo(p.to)) continue;
    const list = outgoing.get(p.from) ?? [];
    list.push(p.to);
    outgoing.set(p.from, list);
  }

  const visit = (name: string, depth: number, stack: Set<string>): void => {
    if (stack.has(name)) return;
    if ((out.get(name) ?? -1) >= depth) return;
    out.set(name, depth);
    const next = outgoing.get(name) ?? [];
    const grown = new Set([...stack, name]);
    for (const n of next) visit(n, depth + 1, grown);
  };

  // Seed from what the browser reaches first, then from anything left over -
  // unpackerr, tdarr-node-01, duckdns and node-exporter are nobody's target and
  // would otherwise never be placed at all.
  for (const p of PATHS) {
    if (p.from === "wan") visit(p.to, 1, new Set());
  }
  for (const n of NODES) {
    if (!out.has(n.name) && !n.pod) visit(n.name, 1, new Set());
  }
  return out;
}

/** The rail a box sits on: the first segment topology.ts declares for it, which
 *  mirrors the order of the Network= lines in stacks/. */
function primaryRail(n: Node): string {
  return n.networks[0] ?? "";
}

export function layout(): Layout {
  const ranks = rankNodes();

  const railsWithHub = new Set(NODES.find((n) => n.name === HUB)?.networks ?? []);
  const rails: PlacedRail[] = NETWORKS.map((net, i) => ({
    id: net.id,
    purpose: net.purpose,
    y: TOP_PAD + i * RAIL_GAP,
    members: NODES.filter((n) => n.networks.includes(net.id)).length,
    detached: !railsWithHub.has(net.id),
  }));
  const railY = new Map(rails.map((r) => [r.id, r.y]));

  // Everything except the hub and the pod members, which are drawn nested.
  const placed = NODES.filter((n) => n.name !== HUB && !n.pod);

  // Within a rail, order by rank and pack left to right. Two nodes at the same
  // rank on the same rail simply take successive columns - deterministic, and
  // it never overlaps, which a rank-as-absolute-x scheme cannot promise.
  const byRail = new Map<string, Node[]>();
  for (const n of placed) {
    const rail = primaryRail(n);
    const list = byRail.get(rail) ?? [];
    list.push(n);
    byRail.set(rail, list);
  }

  const nodes: PlacedNode[] = [];
  let maxCol = 0;
  for (const [rail, members] of byRail) {
    members.sort((a, b) => (ranks.get(a.name) ?? 9) - (ranks.get(b.name) ?? 9) || a.name.localeCompare(b.name));
    members.forEach((n, col) => {
      maxCol = Math.max(maxCol, col);
      nodes.push({
        name: n.name,
        role: n.role,
        x: LEFT_GUTTER + col * (NODE_W + COL_GAP),
        y: (railY.get(rail) ?? TOP_PAD) - NODE_H / 2,
        w: NODE_W,
        h: NODE_H,
        rail,
        rails: n.networks,
        rank: ranks.get(n.name) ?? 1,
        members: NODES.filter((m) => m.pod === n.name),
      });
    });
  }

  const hubNode = NODES.find((n) => n.name === HUB);
  const hubRails = (hubNode?.networks ?? []).map((r) => railY.get(r) ?? 0);
  const hub: PlacedNode | undefined = hubNode && {
    name: HUB,
    role: hubNode.role,
    // The hub spans every rail it joins. Drawn as one tall box rather than
    // seven boxes, because "the only container on more than one segment" is
    // the claim, and seven copies would say the opposite.
    x: HUB_X,
    y: Math.min(...hubRails) - NODE_H / 2,
    w: NODE_W,
    h: Math.max(...hubRails) - Math.min(...hubRails) + NODE_H,
    rail: "",
    rails: hubNode.networks,
    rank: 1,
    members: [],
  };

  return {
    width: LEFT_GUTTER + (maxCol + 1) * (NODE_W + COL_GAP) + 24,
    height: TOP_PAD + (NETWORKS.length - 1) * RAIL_GAP + NODE_H + 34,
    rails,
    nodes,
    hub,
  };
}

/**
 * Rate to a 0..1 intensity.
 *
 * LOGARITHMIC, because the quantity spans five orders of magnitude here: ntfy
 * moves bytes a second and the torrent tunnel moves megabytes. On a linear
 * scale 1 MB/s lands at 0.01 and every real reading sits in the bottom one
 * percent, so every edge would look identical to idle. Log puts 1 MB/s near
 * 0.6, and it matches how format.ts already thinks - in binary decades.
 *
 * Below the floor the answer is 0 rather than a small number: a link carrying
 * a keepalive is idle, and drawing it as moving spends the reader's attention
 * on nothing.
 */
export const RATE_FLOOR = 1024;
export const RATE_CEIL = 100 * 1024 ** 2;

export function intensity(rate: number): number {
  if (!Number.isFinite(rate) || rate < RATE_FLOOR) return 0;
  const t = Math.log(rate / RATE_FLOOR) / Math.log(RATE_CEIL / RATE_FLOOR);
  return Math.min(1, Math.max(0, t));
}

/** Seconds per dash cycle. Faster is busier; the range is deliberately narrow
 *  so that "moving" and "moving fast" stay distinguishable from "still". */
export function flowDuration(rate: number): number {
  return 6 - intensity(rate) * 5;
}

/**
 * The spoke from a box to one of its rails.
 *
 * Two shapes, because the hub is a different case rather than a bigger one. It
 * SPANS every rail it joins, so at each rail its right edge is already at the
 * right height and the spoke is a short horizontal stub - seven of them, no
 * crossings, and the picture says "this one box touches all of these" without a
 * caption. Every other box sits ON its primary rail, so that spoke has zero
 * length and is skipped; a spoke to a SECOND rail is the vertical line, and
 * there are only four of those in the whole stack.
 */
export function spokePath(n: PlacedNode, railYValue: number, hub = false): string {
  if (hub) return `M ${n.x + n.w} ${railYValue} H ${n.x + n.w + COL_GAP - 8}`;
  const x = n.x + n.w / 2;
  const y = n.y + n.h / 2;
  if (Math.abs(railYValue - y) < 1) return "";
  return `M ${x} ${y} V ${railYValue}`;
}

/** Fit a role line to the box. Measured rather than guessed: Azeret Mono at
 *  9.5px is about 5.9px a character, and a role that overflows its box reads as
 *  a rendering bug rather than as a truncation. */
export function fitRole(role: string, width = NODE_W): string {
  const max = Math.floor((width - 18) / 5.9);
  return role.length <= max ? role : `${role.slice(0, max - 1)}.`;
}
