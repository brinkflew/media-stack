// =============================================================================
// The network topology, as declared in stacks/
// -----------------------------------------------------------------------------
// THIS IS A SECOND COPY OF SOMETHING GIT ALREADY OWNS, and CLAUDE.md has a name
// for that shape: when it rejects split-horizon DNS it calls a hand-maintained
// duplicate of the Caddyfile's site blocks "the most driftable shape this
// repository has a name for". The objection is correct and applies here.
//
// It is acceptable only because it is CHECKED. bin/lint-repo.sh parses every
// ContainerName=, Network=, Pod= and PublishPort= out of stacks/ and fails when
// the result differs from this file. So the duplicate cannot quietly become
// fiction; it can only fail the lint.
//
// Why duplicate it at all rather than discover it at run time: `podman network
// inspect` is a host call, and no container may make one - the podman socket is
// SELinux-denied from container_t, which is the same constraint that puts the
// whole read-only decision in the plan. Discovering it in the collector would
// work, but the topology only changes when these files change, and these files
// ARE the authority. Reading git is more honest than re-deriving git.
// =============================================================================

export interface NetworkSegment {
  id: string;
  /** What the segment is for, in one line. Shown under the label. */
  purpose: string;
  /** The .env key carrying its subnet, so the lint can match on it too. */
  subnetVar: string;
}

export interface Node {
  /** podman's ContainerName=, which is also the `container` metric label. */
  name: string;
  networks: string[];
  /** Set for the three containers that have no network stack of their own. */
  pod?: string;
  /** Host publishes, "hostPort -> containerPort". Almost always empty. */
  publishes?: string[];
  /** One line, for the node's subtitle. */
  role: string;
}

/**
 * Ordered as the design reads them: ingress and identity first, then the
 * application segments, then observability, then the two singletons.
 */
export const NETWORKS: NetworkSegment[] = [
  { id: "net-ingress", purpose: "TLS termination and sign-on", subnetVar: "NET_SUBNET_INGRESS" },
  { id: "net-dashboard", purpose: "this page, and nothing else", subnetVar: "NET_SUBNET_DASHBOARD" },
  { id: "net-arr", purpose: "the library managers", subnetVar: "NET_SUBNET_ARR" },
  { id: "net-solver", purpose: "attacker-controlled pages", subnetVar: "NET_SUBNET_SOLVER" },
  { id: "net-download", purpose: "the VPN namespace", subnetVar: "NET_SUBNET_DOWNLOAD" },
  { id: "net-media", purpose: "playback", subnetVar: "NET_SUBNET_MEDIA" },
  { id: "net-transcode", purpose: "the encoder", subnetVar: "NET_SUBNET_TRANSCODE" },
  { id: "net-metrics", purpose: "observability", subnetVar: "NET_SUBNET_METRICS" },
  { id: "net-agents", purpose: "the coding-agent control plane", subnetVar: "NET_SUBNET_AGENTS" },
  { id: "net-egress", purpose: "dynamic DNS", subnetVar: "NET_SUBNET_EGRESS" },
];

export const NODES: Node[] = [
  {
    name: "caddy",
    role: "reverse proxy, the only multi-homed thing here",
    networks: [
      "net-ingress",
      "net-arr",
      "net-download",
      "net-media",
      "net-transcode",
      "net-metrics",
      "net-dashboard",
      "net-agents",
    ],
    publishes: ["80 -> 80", "443 -> 443"],
  },
  { name: "tinyauth", role: "forward-auth bridge", networks: ["net-ingress"] },
  { name: "pocket-id", role: "OIDC provider, passkeys", networks: ["net-ingress"] },

  { name: "dashboard", role: "this page, static files only", networks: ["net-dashboard"] },

  { name: "sonarr", role: "series", networks: ["net-arr", "net-download"] },
  { name: "radarr", role: "films", networks: ["net-arr", "net-download"] },
  { name: "prowlarr", role: "indexers", networks: ["net-arr", "net-download", "net-solver"] },
  { name: "bazarr", role: "subtitles", networks: ["net-arr"] },
  { name: "unpackerr", role: "extraction, polls the queue APIs", networks: ["net-arr"] },
  { name: "jellyseerr", role: "requests", networks: ["net-arr", "net-media"] },

  { name: "flaresolverr", role: "headless Chrome, deliberately alone", networks: ["net-solver"] },

  { name: "torrent", role: "pod infra: holds the network for all three", networks: ["net-download"] },
  { name: "gluetun", role: "VPN, the egress chokepoint", networks: [], pod: "torrent" },
  { name: "qbittorrent", role: "downloader, no stack of its own", networks: [], pod: "torrent" },
  { name: "joal", role: "announcer, no stack of its own", networks: [], pod: "torrent" },

  { name: "jellyfin", role: "playback, initiates nothing", networks: ["net-media"], publishes: ["8096 -> 8096"] },

  { name: "tdarr-server", role: "transcode orchestration", networks: ["net-transcode"] },
  { name: "tdarr-node-01", role: "the encoder worker", networks: ["net-transcode"] },

  { name: "prometheus", role: "the store, 400 days", networks: ["net-metrics"] },
  { name: "node-exporter", role: "host series and the textfile drop", networks: ["net-metrics"] },
  { name: "alertmanager", role: "grouping and suppression", networks: ["net-metrics"] },
  { name: "ntfy-alertmanager", role: "webhook to ntfy, stateless", networks: ["net-metrics"] },
  { name: "ntfy", role: "the phone", networks: ["net-metrics"] },

  { name: "duckdns", role: "dynamic DNS", networks: ["net-egress"] },

  { name: "windmill-db", role: "the control plane's database", networks: ["net-agents"] },
  {
    name: "windmill-server",
    role: "the control plane; conduct polls it, it cannot call out",
    networks: ["net-agents"],
    // The bind address is written into the mapping deliberately. bin/lint-repo.sh
    // compares only the text after the last "->", so it cannot see that this
    // publish is loopback-only - and this string is what a reader sees, both as
    // the cell and as the tooltip title.
    publishes: ["127.0.0.1:8300 -> 8000"],
  },
];

/** Members of a segment, in declaration order. */
export function membersOf(network: string): Node[] {
  return NODES.filter((n) => n.networks.includes(network));
}

/** The three containers inside a pod, which have no address of their own. */
export function podMembers(pod: string): Node[] {
  return NODES.filter((n) => n.pod === pod);
}

export function nodeByName(name: string): Node | undefined {
  return NODES.find((n) => n.name === name);
}

/** Every host publish in the stack. Three of them, and they are not alike: two
 *  face the LAN and are governed by firewalld, and windmill-server's is bound to
 *  127.0.0.1, which firewalld never sees. isLoopback is what keeps the UI from
 *  telling the same story about both kinds. */
export const PUBLISHED: { node: string; mapping: string; isLoopback: boolean }[] = NODES.flatMap(
  (n) =>
    (n.publishes ?? []).map((mapping) => ({
      node: n.name,
      mapping,
      isLoopback: mapping.startsWith("127.0.0.1:"),
    })),
);
