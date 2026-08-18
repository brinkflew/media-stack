// =============================================================================
// Fixture answers, keyed by the exact query string
// -----------------------------------------------------------------------------
// It answers by exact match against src/queries.ts rather than by parsing
// PromQL, which means an unrecognised query is a loud empty result rather than
// a plausible wrong one. `assertCoverage()` below turns that into a startup
// error instead: if a query is added to the catalogue and not taught here, the
// dev server says so on the first request.
// =============================================================================

import { ALL_QUERIES, AVAILABILITY, NETWORK, SERVICES, SYSTEM } from "../src/queries";
import { CONTAINERS, wave } from "./model";
import { NODES } from "../src/topology";

type At = (t: number) => number;

interface SeriesSpec {
  metric: Record<string, string>;
  at: At;
}

const constant = (v: number): At => () => v;
const swing = (key: string, base: number, amplitude: number): At => (t) => wave(key, t, base, amplitude);

const GB = 1024 ** 3;
const MB = 1024 ** 2;
const MEM_TOTAL = 16 * GB;

const FS = [
  { mountpoint: "/boot", device: "/dev/nvme0n1p3", fstype: "ext4", size: 350 * MB, avail: 171 * MB },
  { mountpoint: "/var", device: "/dev/nvme0n1p4", fstype: "xfs", size: 233 * GB, avail: 168 * GB },
  { mountpoint: "/var/mnt/media", device: "/dev/mapper/media-media", fstype: "xfs", size: 36000 * GB, avail: 3200 * GB },
];

const DISKS = [
  { device: "sda", model: "ST8000VN004-2M2101", firmware: "SC60", temp: 38, hours: 41207, realloc: 1, pending: 0 },
  { device: "nvme0", model: "Samsung SSD 980 PRO 250GB", firmware: "5B2QGXA7", temp: 44, hours: 12044, realloc: 0, pending: 0 },
];

const INDEXERS = [
  "1337x", "Nyaa", "Nyaa Trusted", "TorrentGalaxy", "YTS", "EZTV", "LimeTorrents",
  "TheRARBG", "Torlock", "Anidex", "AnimeTosho", "SubsPlease", "Rutracker",
];
const DOWN_INDEXERS = ["The Pirate Bay", "1337x.st"];

function bySeries(): Record<string, SeriesSpec[]> {
  const now = Math.floor(Date.now() / 1000);
  const table: Record<string, SeriesSpec[]> = {};

  // --- host ----------------------------------------------------------------
  table[SYSTEM.cpuBusy] = [{ metric: {}, at: swing("cpu", 0.24, 0.16) }];
  table[SYSTEM.memoryUsedRatio] = [{ metric: {}, at: swing("memratio", 0.61, 0.06) }];
  table[SYSTEM.memoryUsed] = [{ metric: {}, at: (t) => wave("memratio", t, 0.61, 0.06) * MEM_TOTAL }];
  table[SYSTEM.memoryTotal] = [{ metric: { __name__: "node_memory_MemTotal_bytes" }, at: constant(MEM_TOTAL) }];
  table[SYSTEM.load1] = [{ metric: { __name__: "node_load1" }, at: swing("load", 2.4, 1.6) }];

  // TWO CARDS, because the host has two and they are not interchangeable. GPU 0's
  // video engines are dead hardware - every NVENC session on it fails - so both
  // consumers are pinned to gpu=1 and card 0 encodes nothing, for ever. A
  // single-card fixture is what let the page ship reading `[0]` off each of these
  // and reporting the idle card's permanent 0% as the encoder utilisation.
  const gpu0 = { gpu: "0", uuid: "GPU-9f1c0b2e" };
  const gpu1 = { gpu: "1", uuid: "GPU-4b7d15a3" };

  table[SYSTEM.gpuEncoder] = [
    { metric: { ...gpu0, engine: "encoder" }, at: constant(0) },
    { metric: { ...gpu1, engine: "encoder" }, at: swing("enc", 0.86, 0.14) },
  ];
  table[SYSTEM.gpuSm] = [
    { metric: { ...gpu0, engine: "sm" }, at: constant(0) },
    { metric: { ...gpu1, engine: "sm" }, at: swing("sm", 0.12, 0.08) },
  ];
  table[SYSTEM.gpuTemp] = [
    { metric: { __name__: "home_server_gpu_temperature_celsius", ...gpu0 }, at: swing("gputemp0", 34, 3) },
    { metric: { __name__: "home_server_gpu_temperature_celsius", ...gpu1 }, at: swing("gputemp", 62, 6) },
  ];
  table[SYSTEM.gpuPower] = [
    { metric: { __name__: "home_server_gpu_power_watts", ...gpu0 }, at: swing("gpupwr0", 22, 4) },
    { metric: { __name__: "home_server_gpu_power_watts", ...gpu1 }, at: swing("gpupwr", 112, 28) },
  ];
  table[SYSTEM.gpuSessions] = [
    { metric: { __name__: "home_server_gpu_encoder_sessions", ...gpu0 }, at: constant(0) },
    { metric: { __name__: "home_server_gpu_encoder_sessions", ...gpu1 }, at: constant(2) },
  ];

  table[SYSTEM.netRx] = [{ metric: {}, at: swing("rx", 6.2e6, 5.5e6) }];
  table[SYSTEM.netTx] = [{ metric: {}, at: swing("tx", 2.1e6, 1.9e6) }];
  table[SYSTEM.diskRead] = [{ metric: {}, at: swing("dr", 18e6, 16e6) }];
  table[SYSTEM.diskWritten] = [{ metric: {}, at: swing("dw", 9e6, 8e6) }];

  table[SYSTEM.cpuPressure] = [{ metric: {}, at: swing("psicpu", 0.04, 0.035) }];
  table[SYSTEM.ioPressure] = [{ metric: {}, at: swing("psiio", 0.09, 0.08) }];

  table[SYSTEM.filesystems] = FS.map((f) => ({
    metric: { __name__: "node_filesystem_size_bytes", device: f.device, fstype: f.fstype, mountpoint: f.mountpoint },
    at: constant(f.size),
  }));
  table[SYSTEM.filesystemAvail] = FS.map((f) => ({
    metric: { __name__: "node_filesystem_avail_bytes", device: f.device, fstype: f.fstype, mountpoint: f.mountpoint },
    at: constant(f.avail),
  }));

  table[SYSTEM.disksInfo] = DISKS.map((d) => ({
    metric: { __name__: "home_server_disk_info", device: d.device, model: d.model, firmware: d.firmware },
    at: constant(1),
  }));
  table[SYSTEM.diskHealth] = DISKS.map((d) => ({ metric: { device: d.device }, at: constant(1) }));
  table[SYSTEM.diskTemp] = DISKS.map((d) => ({ metric: { device: d.device }, at: swing(`t${d.device}`, d.temp, 3) }));
  table[SYSTEM.diskHours] = DISKS.map((d) => ({ metric: { device: d.device }, at: constant(d.hours) }));
  table[SYSTEM.diskWear] = [{ metric: { device: "nvme0" }, at: constant(0.04) }];
  table[SYSTEM.diskReallocated] = DISKS.map((d) => ({ metric: { device: d.device }, at: constant(d.realloc) }));
  table[SYSTEM.diskPending] = DISKS.map((d) => ({ metric: { device: d.device }, at: constant(d.pending) }));
  table[SYSTEM.diskMediaErrors] = [{ metric: { device: "nvme0" }, at: constant(0) }];
  table[SYSTEM.uptime] = [{ metric: {}, at: constant(41 * 86400 + 6 * 3600) }];

  // --- containers ----------------------------------------------------------
  table[SERVICES.info] = CONTAINERS.map((c) => ({
    metric: { __name__: "home_server_container_info", container: c.name, unit: c.unit, image: c.image, pod: c.pod },
    at: constant(1),
  }));
  table[SERVICES.running] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: constant(c.running ? 1 : 0),
  }));
  table[SERVICES.health] = CONTAINERS.filter((c) => c.health !== undefined).map((c) => ({
    metric: { container: c.name },
    at: constant(c.health as number),
  }));
  table[SERVICES.healthDefined] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: constant(c.health === undefined ? 0 : 1),
  }));
  table[SERVICES.restarts] = CONTAINERS.map((c) => ({ metric: { container: c.name }, at: constant(c.restarts) }));
  table[SERVICES.startTime] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: constant(now - c.startedAgo),
  }));
  table[SERVICES.cpu] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: swing(`cpu${c.name}`, c.cpu, c.cpu * 0.55),
  }));
  table[SERVICES.memory] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: swing(`mem${c.name}`, c.memory, c.memory * 0.05),
  }));
  table[SERVICES.memoryHigh] = CONTAINERS.map((c) => ({ metric: { container: c.name }, at: constant(c.memoryHigh) }));
  table[SERVICES.memoryLimit] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: constant(Math.round(c.memoryHigh * 1.5)),
  }));
  table[SERVICES.memoryRefault] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: constant(c.name === "bazarr" ? 840 : 0),
  }));
  table[SERVICES.oomKills] = [{ metric: { container: "bazarr", event: "oom_kill" }, at: constant(4) }];
  table[SERVICES.identityUnresolved] = [{ metric: {}, at: constant(0) }];

  // --- applications --------------------------------------------------------
  table[SERVICES.arrIndexers] = [
    { metric: { service: "sonarr" }, at: constant(11) },
    { metric: { service: "radarr" }, at: constant(13) },
    { metric: { service: "prowlarr" }, at: constant(15) },
  ];
  table[SERVICES.arrQueue] = [
    { metric: { service: "sonarr", state: "total" }, at: constant(3) },
    { metric: { service: "radarr", state: "total" }, at: constant(1) },
  ];
  table[SERVICES.arrHealth] = [
    { metric: { service: "sonarr", severity: "warning" }, at: constant(1) },
    { metric: { service: "radarr", severity: "warning" }, at: constant(0) },
    { metric: { service: "prowlarr", severity: "error" }, at: constant(2) },
  ];
  table[SERVICES.indexerUp] = [
    ...INDEXERS.map((indexer) => ({ metric: { indexer }, at: constant(1) })),
    ...DOWN_INDEXERS.map((indexer) => ({ metric: { indexer }, at: constant(0) })),
  ];
  table[SERVICES.jellyfinSessions] = [{ metric: {}, at: constant(2) }];
  table[SERVICES.tdarrQueue] = [{ metric: {}, at: constant(1) }];
  table[SERVICES.torrentState] = [{ metric: {}, at: constant(0) }];
  table[SERVICES.torrentRate] = [
    { metric: { direction: "download" }, at: swing("dl", 4.4e6, 3.8e6) },
    { metric: { direction: "upload" }, at: swing("ul", 1.2e6, 1.1e6) },
  ];
  table[SERVICES.vpnInfo] = [
    {
      metric: { __name__: "home_server_vpn_info", country: "Netherlands", city: "Amsterdam", organization: "Proton AG" },
      at: constant(1),
    },
  ];

  // --- availability --------------------------------------------------------
  // bazarr has had a bad fortnight; everything else is flat. The oldest six
  // days are absent entirely, so the strip shows grey rather than inventing
  // history the store does not have.
  table[AVAILABILITY.containerHourly] = CONTAINERS.map((c) => ({
    metric: { container: c.name },
    at: (t) => {
      const daysAgo = Math.round((now - t) / 86400);
      if (daysAgo > 23) return Number.NaN;
      if (c.name === "bazarr") return daysAgo < 3 ? 0.62 : daysAgo < 9 ? 0.981 : 1;
      if (c.name === "flaresolverr" && daysAgo === 11) return 0.94;
      return 1;
    },
  }));

  // --- the store's own pulse query ----------------------------------------
  table['{__name__=~"up|home_server_collector_last_success_timestamp_seconds"}'] = [
    { metric: { __name__: "up", job: "prometheus", instance: "127.0.0.1:9090" }, at: constant(1) },
    { metric: { __name__: "up", job: "node", instance: "node-exporter:9100" }, at: constant(1) },
    {
      metric: { __name__: "home_server_collector_last_success_timestamp_seconds" },
      at: (t) => t - 12,
    },
  ];


  // --- the segments, per container ----------------------------------------
  // Derived from NODES so a topology change cannot leave the fixtures behind,
  // the same reason model.ts builds CONTAINERS from it. Pod members declare
  // networks: [] and are absent here for the reason the collector dedupes on
  // the namespace inode: the four of them read one set of counters, charged
  // once to the infra container.
  //
  // ASYMMETRIC ON PURPOSE. jellyfin streams out, the torrent pod pulls in,
  // dashboard is nearly nothing. A fixture where rx and tx matched would let a
  // page that had swapped them look perfectly correct.
  const NET_RATE: Record<string, [number, number]> = {
    "jellyfin/net-media": [0.4e6, 24e6],
    "caddy/net-media": [24e6, 0.5e6],
    "torrent-infra/net-download": [0.9e6, 3.1e6],
    "torrent-infra/tunnel": [4.4e6, 1.2e6],
    "caddy/net-dashboard": [2e3, 41e3],
    "dashboard/net-dashboard": [41e3, 2e3],
    "prowlarr/net-solver": [12e3, 1.1e6],
    "flaresolverr/net-solver": [1.1e6, 12e3],
  };
  const netPairs = NODES.flatMap((n) =>
    n.networks.map((network) => ({ container: n.name, network })),
  ).concat([{ container: "torrent-infra", network: "tunnel" }]);

  // bazarr on net-arr is deliberately ABSENT, so the "not measured" grey is on
  // screen in dev - the same discipline as the six missing uptime days.
  const measured = netPairs.filter((p) => !(p.container === "bazarr" && p.network === "net-arr"));

  const rateFor = (c: string, n: string): [number, number] =>
    NET_RATE[`${c}/${n}`] ?? [18e3, 9e3];

  table[NETWORK.rx] = measured.map((p) => ({
    metric: { container: p.container, network: p.network },
    at: swing(`nrx${p.container}${p.network}`, rateFor(p.container, p.network)[0],
              rateFor(p.container, p.network)[0] * 0.5),
  }));
  table[NETWORK.tx] = measured.map((p) => ({
    metric: { container: p.container, network: p.network },
    at: swing(`ntx${p.container}${p.network}`, rateFor(p.container, p.network)[1],
              rateFor(p.container, p.network)[1] * 0.5),
  }));
  table[NETWORK.pairs] = [{ metric: {}, at: constant(measured.length) }];
  table[NETWORK.unmapped] = [{ metric: {}, at: constant(0) }];

  return table;
}

let cache: Record<string, SeriesSpec[]> | null = null;

function table(): Record<string, SeriesSpec[]> {
  if (!cache) cache = bySeries();
  return cache;
}

/** Names every catalogued query the fixtures do not answer. */
export function uncovered(): string[] {
  const known = table();
  // ALL_QUERIES, not a second hand-written list of the groups. This function
  // re-enumerated SYSTEM/SERVICES/AVAILABILITY by hand, so a NEW group in
  // queries.ts was covered by nothing and said nothing about it - a coverage
  // check that silently stops covering things is the exact shape of the
  // problem it exists to catch.
  return ALL_QUERIES.filter((q) => !(q in known));
}

function format(v: number): string {
  return Number.isFinite(v) ? String(Math.round(v * 1e6) / 1e6) : "NaN";
}

export function instant(query: string, at: number): unknown {
  const specs = table()[query] ?? [];
  return {
    status: "success",
    data: {
      resultType: "vector",
      result: specs
        .map((s) => ({ metric: s.metric, value: [at, format(s.at(at))] }))
        .filter((s) => s.value[1] !== "NaN"),
    },
  };
}

export function range(query: string, start: number, end: number, step: number): unknown {
  const specs = table()[query] ?? [];
  const result = specs.map((s) => {
    const values: [number, string][] = [];
    for (let t = start; t <= end; t += step) {
      const v = s.at(t);
      // A hole in the fixture is an ABSENT sample, exactly as Prometheus
      // returns it - not a NaN string. That is what exercises the gap
      // handling in charts.ts rather than papering over it.
      if (Number.isFinite(v)) values.push([t, format(v)]);
    }
    return { metric: s.metric, values };
  });

  return { status: "success", data: { resultType: "matrix", result: result.filter((r) => r.values.length) } };
}
