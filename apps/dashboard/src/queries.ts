// =============================================================================
// Every PromQL expression this dashboard issues, in one place
// -----------------------------------------------------------------------------
// Centralised for two reasons, and the second is the one that matters:
//
//   1. A query written inline in a component is invisible to review. The set
//      of things this page asks of Prometheus IS the interface between the
//      dashboard and bin/collect-metrics.py, and an interface belongs in a
//      file somebody can read end to end.
//
//   2. THE DEV FIXTURES ANSWER BY EXACT QUERY STRING. fixtures/server.ts
//      imports this module, so a query that is edited here and not taught to
//      the fixtures fails loudly in `npm run dev` instead of silently
//      rendering an empty panel. A fixture that has quietly stopped covering
//      the real queries is the same shape of problem as a lint that matches
//      nothing.
//
// NAMING: `home_server_*` comes from bin/collect-metrics.py, `node_*` from
// node-exporter or from the collector standing in for a collector that cannot
// run rootless, `container_*` is the cAdvisor-compatible set the collector
// emits from cgroup files. CLAUDE.md's naming contract governs which is which;
// none of it is guessed here.
// =============================================================================

/** rate() needs a window comfortably wider than the 30s scrape. */
const RATE = "5m";

export const SYSTEM = {
  /** Busy fraction of all cores. mode="idle" is the only reliable one. */
  cpuBusy: `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[${RATE}]))`,

  /**
   * MemAvailable, not MemFree. Free excludes reclaimable page cache, so a
   * healthy Linux host looks permanently out of memory - which is the same
   * misreading CLAUDE.md documents at length for Jellyfin's cgroup.
   */
  memoryUsed: "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes",
  memoryUsedRatio: "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes",
  memoryTotal: "node_memory_MemTotal_bytes",

  load1: "node_load1",

  /** The encoder block, which saturates long before the SM does: CLAUDE.md
   *  records two NVENC sessions pinning it at 100% with the SM at 10%. */
  gpuEncoder: 'home_server_gpu_utilization_ratio{engine="encoder"}',
  gpuSm: 'home_server_gpu_utilization_ratio{engine="sm"}',
  gpuTemp: "home_server_gpu_temperature_celsius",
  gpuPower: "home_server_gpu_power_watts",
  gpuSessions: "home_server_gpu_encoder_sessions",

  /** Physical interfaces only. veth* is already excluded by the collector,
   *  but lo is not and would double every number. */
  netRx: `sum(rate(node_network_receive_bytes_total{device!="lo"}[${RATE}]))`,
  netTx: `sum(rate(node_network_transmit_bytes_total{device!="lo"}[${RATE}]))`,

  diskRead: `sum(rate(node_disk_read_bytes_total[${RATE}]))`,
  diskWritten: `sum(rate(node_disk_written_bytes_total[${RATE}]))`,

  /**
   * CPU pressure: the share of time at least one task was stalled waiting for
   * a runnable CPU. This is the number that was pinned when the host wedged
   * under 470 queued health checks while still answering ICMP - utilisation
   * looked survivable and pressure did not.
   */
  cpuPressure: `rate(node_pressure_cpu_waiting_seconds_total[${RATE}])`,
  ioPressure: `rate(node_pressure_io_stalled_seconds_total[${RATE}])`,

  filesystems: "node_filesystem_size_bytes",
  filesystemAvail: "node_filesystem_avail_bytes",

  disksInfo: "home_server_disk_info",
  diskHealth: "home_server_disk_health_ok",
  diskTemp: "home_server_disk_temperature_celsius",
  diskHours: "home_server_disk_power_on_hours",
  diskWear: "home_server_disk_nvme_wear_ratio",
  diskReallocated: "home_server_disk_reallocated_sectors",
  diskPending: "home_server_disk_pending_sectors",
  diskMediaErrors: "home_server_disk_media_errors_total",

  uptime: "home_server_uptime_seconds",
} as const;

export const SERVICES = {
  /**
   * The identity join. podman's own PODMAN_SYSTEMD_UNIT label is what maps
   * torrent-infra to torrent-pod.service with no lookup table, and CLAUDE.md
   * is emphatic that a table maintained in a script is the most driftable
   * thing here. Everything else on the page keys on `container`.
   */
  info: "home_server_container_info",
  running: "home_server_container_running",
  /** 0 healthy, 1 starting, 2 unhealthy. ABSENT for duckdns and unpackerr,
   *  which serve no HTTP and define no health check - absent, not zero. */
  health: "home_server_container_health",
  healthDefined: "home_server_container_healthcheck_defined",
  restarts: "home_server_container_restarts_total",
  startTime: "container_start_time_seconds",

  cpu: `rate(container_cpu_usage_seconds_total[${RATE}])`,
  /** Working set, NOT usage_bytes. The latter counts cold page cache and is
   *  the reason Jellyfin looks like it is at its ceiling when it needs 400 MB. */
  memory: "container_memory_working_set_bytes",
  memoryHigh: "home_server_container_memory_high_bytes",
  memoryLimit: "container_spec_memory_limit_bytes",
  /** Real starvation, as opposed to a cgroup doing ordinary file I/O. */
  memoryRefault: `rate(home_server_container_memory_workingset_refault_file_total[${RATE}])`,
  oomKills: 'home_server_container_memory_events_total{event="oom_kill"}',

  identityUnresolved: "home_server_container_identity_unresolved",

  /** The applications, for the service strip. */
  arrIndexers: "home_server_arr_indexers",
  arrQueue: 'home_server_arr_queue_items{state="total"}',
  arrHealth: "home_server_arr_health_issues",
  indexerUp: "home_server_indexer_up",
  jellyfinSessions: "home_server_jellyfin_sessions_total",
  tdarrQueue: "home_server_tdarr_queue_files_total",
  torrentState: "home_server_torrent_connection_state",
  torrentRate: "home_server_torrent_rate_bytes_per_second",
  vpnInfo: "home_server_vpn_info",
} as const;

export const AVAILABILITY = {
  /**
   * HOURLY, NOT DAILY, AND THE STEP IS WHY. Averaging server-side is still the
   * point - thirty days of raw 30s samples for twenty containers would be about
   * 1.7 million points for a strip of thirty bars - but a 1d average fetched at
   * a 1d step lands its buckets on UTC midnight, which is not where the bars
   * are: src/uptime.ts buckets into LOCAL days, on purpose. Asking for one point
   * per day therefore handed it exactly one sample per bar, aligned to the wrong
   * midnight. An hourly average at a 1h step is 721 points per series - well
   * inside Prometheus' 11,000-point cap, where a 30s step over 30 days is a 400
   * - and gives every local day twenty-four samples to average.
   */
  containerHourly: "avg_over_time(home_server_container_running[1h])",
} as const;

/** Flattened, so the fixtures can assert they cover every one of them. */
export const ALL_QUERIES: string[] = [
  ...Object.values(SYSTEM),
  ...Object.values(SERVICES),
  ...Object.values(AVAILABILITY),
];
