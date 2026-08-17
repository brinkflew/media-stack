// =============================================================================
// A synthetic host, for developing against
// -----------------------------------------------------------------------------
// Deterministic, offline, and DELIBERATELY UNHEALTHY. A fixture where
// everything passes exercises exactly the state that needs the least design
// work; the interesting layouts are the actionable strip with something in it,
// a panel that has gone stale, a container in a restart loop, a disk with a
// reallocated sector. So this host has all of those, and they are the same
// failures the real one has actually had.
//
// Nothing here ships: fixtures/ is imported only by vite.config.ts, which drops
// the plugin entirely when VITE_PROM is set, and the production image serves a
// bundle that has never referenced this file.
// =============================================================================

import { NODES } from "../src/topology";
import type { AmAlert, Check, StatusDocument } from "../src/types";

// -----------------------------------------------------------------------------
// A seeded generator, so two reloads look the same and a layout bug does not
// hide behind fresh noise.
// -----------------------------------------------------------------------------
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

/** A smooth-ish waveform with a stable shape per key. */
export function wave(key: string, t: number, base: number, swing: number): number {
  let h = 0;
  for (let i = 0; i < key.length; i += 1) h = (h * 31 + key.charCodeAt(i)) >>> 0;
  const phase = (h % 1000) / 1000;
  const slow = Math.sin(t / 1800 + phase * 6.283) * 0.6;
  const fast = Math.sin(t / 240 + phase * 12.566) * 0.25;
  const jitter = (rng(h ^ Math.floor(t / 30))() - 0.5) * 0.3;
  return Math.max(0, base + swing * (slow + fast + jitter));
}

// -----------------------------------------------------------------------------
// The containers, taken from the same topology module the app reads, so a node
// added there shows up here without a second edit.
// -----------------------------------------------------------------------------
const IMAGES: Record<string, string> = {
  caddy: "localhost/home-server/caddy:latest",
  dashboard: "localhost/home-server/dashboard:latest",
  tinyauth: "ghcr.io/steveiliop56/tinyauth:v5",
  "pocket-id": "ghcr.io/pocket-id/pocket-id:v2",
  sonarr: "lscr.io/linuxserver/sonarr:latest",
  radarr: "lscr.io/linuxserver/radarr:latest",
  prowlarr: "lscr.io/linuxserver/prowlarr:develop",
  bazarr: "lscr.io/linuxserver/bazarr:latest",
  unpackerr: "ghcr.io/unpackerr/unpackerr:latest",
  jellyseerr: "docker.io/fallenbagel/jellyseerr:latest",
  flaresolverr: "ghcr.io/flaresolverr/flaresolverr:latest",
  jellyfin: "lscr.io/linuxserver/jellyfin:latest",
  "tdarr-server": "ghcr.io/haveagitgat/tdarr:latest",
  "tdarr-node-01": "ghcr.io/haveagitgat/tdarr_node:latest",
  prometheus: "quay.io/prometheus/prometheus:v3",
  "node-exporter": "quay.io/prometheus/node-exporter:v1",
  alertmanager: "quay.io/prometheus/alertmanager:v0",
  "ntfy-alertmanager": "docker.io/xenrox/ntfy-alertmanager:latest",
  ntfy: "docker.io/binwiederhier/ntfy:v2",
  duckdns: "lscr.io/linuxserver/duckdns:latest",
  gluetun: "docker.io/qmcgaw/gluetun:v3",
  qbittorrent: "lscr.io/linuxserver/qbittorrent:libtorrentv1",
  joal: "docker.io/anthonyraymond/joal:latest",
  torrent: "localhost/podman-pause:5.4.0",
};

/** Memory ceilings, matching the MemoryHigh= in stacks/. */
const MEM_HIGH: Record<string, number> = {
  jellyfin: 3 * 1024 ** 3,
  "tdarr-server": 2 * 1024 ** 3,
  "tdarr-node-01": 6 * 1024 ** 3,
  prometheus: 512 * 1024 ** 2,
  caddy: 512 * 1024 ** 2,
  sonarr: 1024 ** 3,
  radarr: 1024 ** 3,
  prowlarr: 512 * 1024 ** 2,
  bazarr: 512 * 1024 ** 2,
  qbittorrent: 1024 ** 3,
  dashboard: 64 * 1024 ** 2,
};

export interface FixtureContainer {
  name: string;
  unit: string;
  image: string;
  pod: string;
  /** 0 healthy, 1 starting, 2 unhealthy. undefined = no health check defined. */
  health?: number;
  running: boolean;
  restarts: number;
  cpu: number;
  memory: number;
  memoryHigh: number;
  startedAgo: number;
}

export const CONTAINERS: FixtureContainer[] = NODES.map((n) => {
  const pod = n.pod ?? (n.name === "torrent" ? "torrent" : "");
  // duckdns and unpackerr serve no HTTP and define no health check. The metric
  // is ABSENT for them rather than zero, which is what lets a rule cover every
  // container without naming any - see CLAUDE.md.
  const noHealth = n.name === "duckdns" || n.name === "unpackerr" || n.name === "torrent";

  return {
    name: n.name,
    unit: n.pod ? "torrent-pod.service" : `${n.name}.service`,
    image: IMAGES[n.name] ?? "docker.io/library/unknown:latest",
    pod,
    health: noHealth ? undefined : 0,
    running: true,
    restarts: 0,
    cpu: 0.01,
    memory: 64 * 1024 ** 2,
    memoryHigh: MEM_HIGH[n.name] ?? 256 * 1024 ** 2,
    startedAgo: 41 * 86400 + 6 * 3600,
  };
});

// --- the two live problems, so the actionable layer has something in it ------
function patch(name: string, changes: Partial<FixtureContainer>): void {
  const c = CONTAINERS.find((x) => x.name === name);
  if (c) Object.assign(c, changes);
}

patch("bazarr", { health: 2, restarts: 4, startedAgo: 96, memory: 508 * 1024 ** 2 });
// A REAL, BENIGN AMBER. Jellyseerr genuinely takes about forty seconds to pass
// its health check after a restart, so `health: 1` here is a state the host
// actually reaches rather than an invented one - and nothing else in this fixture
// exercises the "starting" branch that ServicesPage and the Home strip both have.
// With bazarr already unhealthy and unpackerr defining no check at all, the strip
// then renders all four tones at once, which is the point of a fixture.
patch("jellyseerr", { health: 1, startedAgo: 40, memory: 180 * 1024 ** 2 });
patch("jellyfin", { cpu: 3.9, memory: 2.99 * 1024 ** 3, startedAgo: 15 * 3600 + 38 * 60 });
patch("tdarr-node-01", { cpu: 1.6, memory: 1.4 * 1024 ** 3 });
patch("prowlarr", { cpu: 0.06, memory: 220 * 1024 ** 2 });
patch("prometheus", { cpu: 0.11, memory: 402 * 1024 ** 2 });
patch("qbittorrent", { cpu: 0.22, memory: 610 * 1024 ** 2 });
patch("caddy", { cpu: 0.03, memory: 88 * 1024 ** 2 });
patch("dashboard", { cpu: 0.002, memory: 14 * 1024 ** 2 });

// -----------------------------------------------------------------------------
// status.json
// -----------------------------------------------------------------------------
const CHECKS: Check[] = [
  { section: "net", id: "net.lan_address", status: "pass", message: "192.168.0.100 on enp3s0" },
  { section: "deploy", id: "deploy.booted", status: "pass", message: "ucore stable-nvidia-lts, 2 deployments" },
  { section: "deploy", id: "deploy.image_tag", status: "pass", message: "stable-nvidia-lts" },
  { section: "deploy", id: "deploy.image_signed", status: "pass", message: "ostree-image-signed, cosign scope matches" },
  { section: "deploy", id: "deploy.pinned", status: "pass", message: "nothing pinned" },
  { section: "deploy", id: "deploy.update_policy", status: "pass", message: "AutomaticUpdatePolicy=stage" },
  { section: "deploy", id: "deploy.update_timer", status: "pass", message: "rpm-ostreed-automatic.timer armed" },
  { section: "deploy", id: "deploy.boot_free", status: "pass", message: "171 MB free of 350 MB" },
  { section: "deploy", id: "deploy.update_run", status: "pass", message: "last ran 9h ago" },
  { section: "storage", id: "storage.media_mount", status: "warn", message: "/mnt/media 91% used, 3.2 TB free of 36 TB" },
  { section: "gpu_cdi", id: "gpu.count", status: "pass", message: "1 GPU visible" },
  { section: "gpu_cdi", id: "cdi.spec_count", status: "pass", message: "exactly one spec at /run/cdi/nvidia.yaml" },
  { section: "gpu_cdi", id: "cdi.driver_match", status: "pass", message: "spec names 580.173.02, which is running" },
  { section: "gpu_cdi", id: "cdi.refresh_watcher", status: "pass", message: "nvidia-cdi-refresh.path active" },
  { section: "host", id: "host.container_use_devices", status: "pass", message: "on" },
  { section: "host", id: "host.failed_units", status: "pass", message: "no failed system units" },
  { section: "host", id: "host.firewalld", status: "pass", message: "FedoraServer, stack ports open" },
  { section: "host", id: "host.io_delegated", status: "pass", message: "cpu io memory pids delegated to user@1000" },
  { section: "host", id: "host.linger", status: "pass", message: "enabled for core" },
  { section: "greenboot", id: "greenboot.installed", status: "pass", message: "greenboot layered" },
  { section: "greenboot", id: "greenboot.armed", status: "pass", message: "boot counter armed via /boot/grub2/custom.cfg" },
  { section: "greenboot", id: "greenboot.verdict", status: "pass", message: "last boot green" },
  { section: "reboot", id: "reboot.timer_enabled", status: "pass", message: "home-server-reboot.timer armed" },
  { section: "reboot", id: "reboot.last_applied", status: "pass", message: "applied 6d ago" },
  { section: "update", id: "update.podman_timer", status: "pass", message: "podman-auto-update.timer armed" },
  { section: "update", id: "update.caddy_build_timer", status: "pass", message: "home-server-caddy-build.timer armed" },
  { section: "update", id: "update.dashboard_build_timer", status: "pass", message: "home-server-dashboard-build.timer armed" },
  { section: "update", id: "update.policy_count", status: "pass", message: "18 units carry an AutoUpdate policy" },
  { section: "update", id: "update.podman_run", status: "pass", message: "last ran 9h ago" },
  { section: "backup", id: "backup.timer_enabled", status: "pass", message: "home-server-backup.timer armed" },
  { section: "backup", id: "backup.run", status: "pass", message: "last ran 6h ago" },
  { section: "backup", id: "backup.local_age", status: "pass", message: "6h old, fails at 48h" },
  { section: "backup", id: "backup.offsite_age", status: "pass", message: "6h old, fails at 72h" },
  { section: "backup", id: "backup.offsite_prune_age", status: "warn", message: "33 days since the last off-site prune, warns at 30" },
  { section: "backup", id: "backup.offsite_delete_denial", status: "pass", message: "refused with 403 six hours ago" },
  { section: "backup", id: "backup.tsdb_snapshot_age", status: "pass", message: "6h old" },
  { section: "checkout", id: "checkout.clean", status: "pass", message: "working tree clean" },
  { section: "checkout", id: "checkout.matches_origin", status: "pass", message: "at origin/main" },
  { section: "containers", id: "containers.failed_units", status: "fail", message: "bazarr.service failed: oom-kill, 4 restarts in the last hour" },
  {
    section: "containers",
    id: "containers.healthy",
    status: "fail",
    // Kept consistent with the CONTAINERS patches above: bazarr unhealthy and
    // jellyseerr still starting. Three sources disagreeing about the same host is
    // exactly the confusion a fixture is supposed to avoid.
    message: "bazarr unhealthy, jellyseerr starting; 21 of 23 healthy",
  },
  { section: "containers", id: "containers.gpu_jellyfin", status: "pass", message: "nvidia device present" },
  { section: "containers", id: "containers.gpu_tdarr_node_01", status: "pass", message: "nvidia device present" },
  { section: "logs", id: "logs.persistent", status: "pass", message: "Storage=persistent" },
  { section: "logs", id: "logs.disk_usage", status: "pass", message: "1.2 GB of a 16 GB cap" },
  { section: "logs", id: "logs.retention", status: "pass", message: "90 days" },
  { section: "logs", id: "logs.dropin_loaded", status: "pass", message: "10-home-server.conf parsed by PID 1" },
  { section: "logs", id: "logs.dropin_values", status: "pass", message: "MaxRetentionSec and SystemMaxUse both in force" },
  { section: "logs", id: "logs.suppressed_24h", status: "pass", message: "nothing rate-limited in 24h" },
  { section: "logs", id: "logs.healthcheck_events", status: "pass", message: "0 health_status events in the last hour" },
  { section: "logs", id: "logs.config_log_size", status: "pass", message: "11 MB across 69 files" },
  { section: "metrics", id: "metrics.timer_enabled", status: "pass", message: "home-server-metrics.timer armed" },
  { section: "metrics", id: "metrics.collector_fresh", status: "pass", message: "last collected 12s ago" },
  { section: "metrics", id: "metrics.prometheus_up", status: "pass", message: "answering on net-metrics" },
  { section: "metrics", id: "metrics.targets_down", status: "pass", message: "2 of 2 targets up" },
  { section: "metrics", id: "metrics.alert_rules", status: "pass", message: "17 rules in 5 groups" },
  { section: "metrics", id: "metrics.alertmanager_up", status: "pass", message: "discovered and answering" },
  { section: "metrics", id: "metrics.alert_delivery", status: "pass", message: "no notification errors in 10m" },
  { section: "metrics", id: "metrics.series_count", status: "pass", message: "2896 series of a 4000 budget" },
  { section: "metrics", id: "metrics.tsdb_size", status: "pass", message: "1.9 GB of a 16 GB cap" },
  { section: "verify", id: "verify.timer_enabled", status: "pass", message: "home-server-verify.timer armed" },
];

const SECTION_TITLES: Record<string, string> = {
  net: "Network",
  deploy: "Deployment",
  storage: "Storage",
  gpu_cdi: "GPU / CDI",
  host: "Host prerequisites",
  greenboot: "Boot health",
  reboot: "Reboot window",
  update: "Container updates",
  backup: "Backups",
  checkout: "Checkout",
  containers: "Containers",
  logs: "Logs",
  metrics: "Metrics",
  verify: "Self",
};

function iso(offsetSeconds: number): string {
  return new Date(Date.now() - offsetSeconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function statusDocument(): StatusDocument {
  const counts = { pass: 0, fail: 0, warn: 0, note: 0 };
  for (const c of CHECKS) counts[c.status] += 1;

  const sections = [...new Set(CHECKS.map((c) => c.section))].map((id) => {
    const own = CHECKS.filter((c) => c.section === id);
    return {
      id,
      title: SECTION_TITLES[id] ?? id,
      pass: own.filter((c) => c.status === "pass").length,
      fail: own.filter((c) => c.status === "fail").length,
      warn: own.filter((c) => c.status === "warn").length,
      note: own.filter((c) => c.status === "note").length,
    };
  });

  return {
    schema: 1,
    // Deliberately a few minutes old, not "now": the battery is hourly and a
    // fixture that is always current hides the freshness affordance entirely.
    generated_at: iso(23 * 60),
    host: "avanserv",
    // The route battery did NOT run, which is the normal case - the hourly
    // timer passes --quiet, not --routes. The UI must say "not measured".
    mode: { routes: false },
    summary: {
      status: counts.fail > 0 ? "fail" : counts.warn > 0 ? "warn" : "pass",
      ...counts,
      total: CHECKS.length,
    },
    sections,
    checks: CHECKS,
    facts: {
      booted_version: "44.20260810.3.0",
      staged_version: "44.20260814.3.0",
      deployments: 2,
      pinned: 0,
      boot_free_mb: 171,
      gpu_count: 1,
      driver_version: "580.173.02",
      red_boot_at: null,
      greenboot_result: "green",
      backup_local_at: iso(6 * 3600),
      backup_offsite_at: iso(6 * 3600),
      backup_offsite_pruned_at: iso(33 * 86400),
      backup_offsite_policy_ok_at: iso(6 * 3600),
      backup_tsdb_snapshot_at: iso(6 * 3600),
      checkout_clean: true,
      containers_running: CONTAINERS.length,
      journal_mb: 1204,
      journal_cap_mb: 16384,
      journal_retention_days: 90,
      journal_suppressed_24h: 0,
      healthcheck_events_15m: 0,
      config_log_mb: 11,
      metrics_last_ok_at: iso(12),
      metrics_collect_age_s: 12,
      metrics_targets_total: 2,
      metrics_targets_down: 0,
      metrics_alert_rules: 17,
      metrics_notify_errors: 0,
      metrics_series: 2896,
      metrics_tsdb_mb: 1946,
      verify_last_run_at: iso(23 * 60),
      verify_last_ok_at: iso(23 * 60),
      verify_fail_count: counts.fail,
      verify_warn_count: counts.warn,
      uptime_s: 41 * 86400 + 6 * 3600,
    },
  };
}

// -----------------------------------------------------------------------------
// Alertmanager
// -----------------------------------------------------------------------------
export function alerts(): AmAlert[] {
  const active = (labels: Record<string, string>, annotations: Record<string, string>, ago: number): AmAlert => ({
    labels,
    annotations,
    startsAt: iso(ago),
    endsAt: "0001-01-01T00:00:00Z",
    updatedAt: iso(30),
    status: { state: "active", silencedBy: [], inhibitedBy: [] },
    fingerprint: Object.values(labels).join("-"),
  });

  return [
    active(
      { alertname: "ContainerUnhealthy", severity: "critical", container: "bazarr" },
      {
        summary: "bazarr is unhealthy",
        description: "home_server_container_health has been 2 for 4 minutes. Last exit was 137.",
      },
      264,
    ),
    active(
      { alertname: "ContainerRestartLoop", severity: "warning", container: "bazarr" },
      { summary: "bazarr restarted 4 times in the last hour", description: "increase(...restarts_total[1h]) > 5" },
      240,
    ),
    active(
      { alertname: "FilesystemFillingUp", severity: "warning", mountpoint: "/var/mnt/media" },
      {
        summary: "/var/mnt/media is 91% full",
        description: "3.2 TB available of 36 TB. At the current rate it fills in about 11 days.",
      },
      52 * 3600,
    ),
    active(
      { alertname: "BackupOffsitePruneStale", severity: "warning", instance: "node-exporter:9100" },
      {
        summary: "the off-site repository has not been pruned for 33 days",
        description: "Retention runs from the workstation: bin/backup-offsite.sh. It grows until it does.",
      },
      3 * 86400,
    ),
  ];
}
