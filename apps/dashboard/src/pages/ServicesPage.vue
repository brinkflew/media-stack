<script setup lang="ts">
/**
 * Services: the container rack, and what the applications are doing.
 *
 * The segmentation, the routes and the traffic moved to NetworkPage on
 * 2026-08-18. The two answer different questions - "is this container healthy"
 * against "what can reach what, and what is moving" - and the second grew a
 * measured data layer that wanted a page of its own.
 *
 * Every row is assembled from home_server_container_info's label set, which is
 * podman's own PODMAN_SYSTEMD_UNIT join - so `torrent-infra` resolves to
 * torrent-pod.service with no lookup table anywhere. CLAUDE.md is emphatic
 * about that: a table maintained in a script is the most driftable thing here.
 *
 * home_server_container_identity_unresolved counts what did not map, and it is
 * shown rather than ignored, because the failure is otherwise silent - a
 * container simply missing from the rack.
 */
import { computed, watch } from "vue";

import PanelBox from "@/components/PanelBox.vue";
import StatusDot from "@/components/StatusDot.vue";
import ActivityBars from "@/components/ActivityBars.vue";
import StaleNote from "@/components/StaleNote.vue";
import WindowPicker from "@/components/WindowPicker.vue";

import { usePoll } from "@/composables/usePoll";
import { useMetricsStale } from "@/composables/useStaleness";
import { useTimeWindow } from "@/composables/useTimeWindow";
import { useTooltip } from "@/composables/useTooltip";
import { containerTone } from "@/health";
import type { Tone } from "@/types";
import { instant, instantBy, labelsBy, range, value } from "@/api/prometheus";
import { SERVICES } from "@/queries";
import { toPoints } from "@/charts";
import { nodeByName } from "@/topology";
import * as fmt from "@/format";

const { window: win } = useTimeWindow();
const tip = useTooltip();

interface Row {
  name: string;
  unit: string;
  image: string;
  pod: string;
  running: boolean;
  /** undefined when the container defines no health check at all. */
  health?: number;
  restarts: number;
  cpu: number;
  memory: number;
  memoryHigh: number;
  /** Pages faulted back in after being reclaimed: the difference between a
   *  cgroup holding cold cache and one that is actually starved. */
  refault: number;
  uptime: number;
  activity: number[];
  networks: string[];
  role: string;
  tone: Tone;
  state: string;
}

const ACTIVITY_BARS = 24;

/**
 * The three LEDs have no legend anywhere on this page, and the leftmost one has
 * a state that cannot be guessed: GREY MEANS NO HEALTH CHECK IS DEFINED, which
 * is not the same as one that passed. @/health encodes that rule and
 * home_server_container_health is absent rather than zero for duckdns,
 * unpackerr and the pod's infra container - so the tooltip has to say it, or
 * the only place it is written down is a source file.
 */
function ledTip(row: Row) {
  return {
    title: row.name,
    lines: [row.state, row.image],
    caveat:
      row.tone === "off"
        ? "Grey is not green. This container defines no health check, so nobody is checking it - which is a different thing from passing."
        : undefined,
  };
}

function runTip(row: Row) {
  return {
    title: row.running ? "running" : "stopped",
    lines: [`up ${fmt.duration(row.uptime)}`, fmt.unitName(row.unit)],
  };
}

function restartTip(row: Row) {
  return {
    title: `${fmt.number(row.restarts)} restart(s)`,
    lines: ["podman's count, since the container was created"],
    caveat:
      row.restarts === 0 && row.uptime < 3600
        ? "The counter is recreated with the container, and auto-update recreates every container nightly. A short uptime with zero restarts is not evidence of stability."
        : undefined,
  };
}

/** The same for every row, so it is computed once rather than rebuilt
 *  twenty-three times on each render. */
const activityTip = computed(() => {
  return {
    title: `CPU, last ${win.value.label}`,
    lines: [
      `${ACTIVITY_BARS} bars, one per ${fmt.duration(Math.round(win.value.seconds / ACTIVITY_BARS))}`,
      "scaled to this row's own peak, not to the rack",
    ],
    caveat: "A grey bar is a missing sample, not an idle one.",
  };
});

function rowTip(row: Row) {
  return {
    title: row.name,
    lines: [
      row.state,
      `up ${fmt.duration(row.uptime)}, ${fmt.number(row.restarts)} restart(s)`,
      `cpu ${fmt.percent(row.cpu, 1)}, memory ${fmt.bytes(row.memory)}`,
      row.networks.length ? row.networks.join(" ") : "no network of its own",
    ],
    caveat: ledTip(row).caveat,
  };
}

const rack = usePoll(async (signal) => {
  const end = Math.floor(Date.now() / 1000);
  const step = Math.max(60, Math.round(win.value.seconds / ACTIVITY_BARS));

  const [info, running, health, restarts, startTime, cpu, memory, memHigh, refault, unresolved, activity] =
    await Promise.all([
      labelsBy(SERVICES.info, "container", signal),
      instantBy(SERVICES.running, "container", signal),
      instantBy(SERVICES.health, "container", signal),
      instantBy(SERVICES.restarts, "container", signal),
      instantBy(SERVICES.startTime, "container", signal),
      instantBy(SERVICES.cpu, "container", signal),
      instantBy(SERVICES.memory, "container", signal),
      instantBy(SERVICES.memoryHigh, "container", signal),
      instantBy(SERVICES.memoryRefault, "container", signal),
      instant(SERVICES.identityUnresolved, signal),
      range(SERVICES.cpu, { window: step * ACTIVITY_BARS, step, signal }),
    ]);

  const bars = new Map<string, number[]>();
  for (const s of activity) {
    const key = s.metric.container;
    if (key) bars.set(key, toPoints(s.values).map(([, v]) => v));
  }

  const rows: Row[] = [...info.entries()].map(([name, labels]) => {
    const isRunning = (running.get(name) ?? 0) === 1;
    const h = health.get(name);
    const declared = nodeByName(name);

    // @/health owns this mapping now: the Home page's service strip needs the
    // identical rule, and "absent is not zero" is too subtle to have two copies.
    const { tone, state } = containerTone(isRunning, h);

    return {
      name,
      unit: labels.unit ?? "",
      image: labels.image ?? "",
      pod: labels.pod ?? "",
      running: isRunning,
      health: h,
      restarts: restarts.get(name) ?? Number.NaN,
      cpu: cpu.get(name) ?? Number.NaN,
      memory: memory.get(name) ?? Number.NaN,
      memoryHigh: memHigh.get(name) ?? Number.NaN,
      refault: refault.get(name) ?? Number.NaN,
      uptime: end - (startTime.get(name) ?? Number.NaN),
      activity: bars.get(name) ?? [],
      networks: declared?.networks ?? [],
      role: declared?.role ?? "",
      tone,
      state,
    };
  });

  // Worst first, then busiest. A rack sorted alphabetically buries the one row
  // worth looking at somewhere in the middle.
  //
  // `off` and `ok` deliberately TIE. duckdns, unpackerr and the pod infra have
  // no health check to fail, so ranking "unchecked" above "healthy" would pin
  // the same three rows to the top for ever - which is how a sort order stops
  // being read. They sort in by activity like everything else.
  const rank: Record<Tone, number> = { fail: 0, warn: 1, off: 2, ok: 2 };
  rows.sort((a, b) => rank[a.tone] - rank[b.tone] || b.cpu - a.cpu);

  return { rows, unresolved: value(unresolved[0]?.value) };
}, 30_000);

watch(win, () => {
  void rack.refresh();
});

const rows = computed(() => rack.data.value?.rows ?? []);

const tally = computed(() => {
  const r = rows.value;
  const counts = { ok: 0, warn: 0, fail: 0, off: 0 };
  for (const row of r) counts[row.tone] += 1;
  return counts;
});

const memoryRatio = (row: Row): number =>
  Number.isFinite(row.memoryHigh) && row.memoryHigh > 0 ? row.memory / row.memoryHigh : Number.NaN;

/**
 * A CONTAINER AT ITS MemoryHigh IS NOT NEWS, and colouring it amber is the
 * single most likely way this page would cry wolf.
 *
 * CLAUDE.md spends a section on it: Jellyfin sits at exactly 3.00G against a
 * 3G watermark with 6,398 `high` events seven minutes after a restart, and it
 * is fine - 0.385G of that is its working set and the rest is cold streaming
 * page cache the kernel reclaims for free. "A cgroup doing file I/O will
 * always sit at its MemoryHigh and always accumulate high events, because that
 * is what the watermark is for."
 *
 * So the ratio alone decides nothing. The second signal is the refault rate -
 * pages being read back in after reclaim, which is what actual starvation
 * looks like - and a restart, which is what it looks like once it has already
 * gone wrong.
 */
function memoryTone(row: Row): Tone {
  const ratio = memoryRatio(row);
  if (!Number.isFinite(ratio)) return "off";

  const thrashing = Number.isFinite(row.refault) && row.refault > 0;
  if (ratio >= 0.98 && (thrashing || row.restarts > 0)) return "fail";
  if (thrashing) return "warn";
  return "ok";
}

// --- the applications, as a strip ------------------------------------------
const apps = usePoll(async (signal) => {
  const [indexers, indexerUp, queue, sessions, tdarr, torrent, torrentRate, vpn] = await Promise.all([
    instantBy(SERVICES.arrIndexers, "service", signal),
    instantBy(SERVICES.indexerUp, "indexer", signal),
    instantBy(SERVICES.arrQueue, "service", signal),
    instant(SERVICES.jellyfinSessions, signal),
    instant(SERVICES.tdarrQueue, signal),
    instant(SERVICES.torrentState, signal),
    instantBy(SERVICES.torrentRate, "direction", signal),
    labelsBy(SERVICES.vpnInfo, "__name__", signal),
  ]);

  const up = [...indexerUp.values()].filter((v) => v === 1).length;
  const vpnLabels = [...vpn.values()][0];

  return {
    indexers: { up, total: indexerUp.size, perService: indexers },
    queue,
    sessions: value(sessions[0]?.value),
    tdarr: value(tdarr[0]?.value),
    torrentState: value(torrent[0]?.value),
    down: torrentRate.get("download") ?? Number.NaN,
    upRate: torrentRate.get("upload") ?? Number.NaN,
    vpn: vpnLabels ? `${vpnLabels.city ?? ""} ${vpnLabels.country ?? ""}`.trim() : "",
  };
}, 60_000);

const TORRENT_STATE = ["connected", "firewalled", "disconnected"];

// @/composables/useStaleness owns this now - it was byte-identical to
// SystemPage's copy, and Home and Library would have made four.
const metricsStale = useMetricsStale();
</script>

<template>
  <div class="page">
    <Teleport defer to="#toolbar">
      <span class="mono note">read only</span>
      <WindowPicker />
    </Teleport>

    <!-- The rack -->
    <section class="rack-head">
      <span class="label">Containers</span>
      <span class="mono counts">
        {{ rows.length }} units / {{ tally.ok }} healthy / {{ tally.warn }} starting /
        {{ tally.fail }} failing / {{ tally.off }} unchecked
      </span>
    </section>

    <StaleNote :reason="metricsStale" />

    <div class="rack" :class="{ dim: !!metricsStale }">
      <div class="row head mono">
        <span>LED</span>
        <span>CONTAINER</span>
        <span>IMAGE</span>
        <span>ACTIVITY</span>
        <span class="r">CPU</span>
        <span class="r">MEMORY</span>
        <span class="r">RESTARTS</span>
        <span class="r">UPTIME</span>
      </div>

      <div
        v-for="row in rows"
        :key="row.name"
        class="row"
        :style="{ borderLeftColor: `var(--${row.tone})` }"
        v-bind="tip.bind(`row-${row.name}`, rowTip(row))"
      >
        <div class="leds">
          <span v-bind="tip.hover(`led-${row.name}`, ledTip(row))">
            <StatusDot :tone="row.tone" :live="row.tone === 'fail'" glow :size="7" />
          </span>
          <span v-bind="tip.hover(`run-${row.name}`, runTip(row))">
            <StatusDot :tone="row.running ? 'ok' : 'off'" :size="7" />
          </span>
          <span v-bind="tip.hover(`rst-${row.name}`, restartTip(row))">
            <StatusDot :tone="row.restarts > 0 ? 'warn' : 'off'" :size="7" />
          </span>
        </div>

        <div class="ident">
          <div class="name">{{ row.name }}</div>
          <div class="state mono" :style="{ color: `var(--${row.tone})` }">{{ row.state }}</div>
        </div>

        <div class="meta">
          <div class="mono image truncate" :title="row.image">{{ fmt.shortImage(row.image) }}</div>
          <div class="mono sub">
            <span>{{ fmt.unitName(row.unit) }}</span>
            <span v-if="row.pod">pod {{ row.pod }}</span>
            <span v-else-if="row.networks.length">{{ row.networks.join(" ") }}</span>
          </div>
        </div>

        <span v-bind="tip.hover(`act-${row.name}`, activityTip)">
          <ActivityBars :values="row.activity" :tone="row.tone === 'off' ? 'off' : row.tone" :height="20" />
        </span>

        <div class="mono num">{{ fmt.percent(row.cpu, 1) }}</div>

        <div class="mono num mem">
          <span>{{ fmt.bytes(row.memory) }}</span>
          <span class="cap" :style="{ color: `var(--${memoryTone(row)})` }">
            {{ fmt.percent(memoryRatio(row), 0) }} of high
          </span>
        </div>

        <div class="mono num" :style="{ color: row.restarts > 0 ? 'var(--warn)' : 'var(--fg-5)' }">
          {{ fmt.number(row.restarts) }}
        </div>

        <div class="mono num dim">{{ fmt.duration(row.uptime) }}</div>
      </div>
    </div>

    <p v-if="(rack.data.value?.unresolved ?? 0) > 0" class="unresolved mono">
      {{ rack.data.value?.unresolved }} container(s) could not be mapped to a systemd unit, so they are
      absent from this table. That is what home_server_container_identity_unresolved counts.
    </p>

    <!-- The applications. The network half of this section moved to
         NetworkPage; what is left is application state, so it reads as a strip
         above nothing rather than a sidebar around one panel. -->
    <PanelBox label="Applications" :stale="metricsStale">
      <div class="apps mono">
        <div class="app">
          <span>indexers up</span>
          <span
            class="av"
            :style="{
              color:
                (apps.data.value?.indexers.up ?? 0) * 2 < (apps.data.value?.indexers.total ?? 0)
                  ? 'var(--warn)'
                  : 'var(--fg-2)',
            }"
          >
            {{ apps.data.value?.indexers.up ?? "-" }} of {{ apps.data.value?.indexers.total ?? "-" }}
          </span>
        </div>
        <div class="app">
          <span>sonarr queue</span>
          <span class="av">{{ fmt.number(apps.data.value?.queue.get("sonarr") ?? Number.NaN) }}</span>
        </div>
        <div class="app">
          <span>radarr queue</span>
          <span class="av">{{ fmt.number(apps.data.value?.queue.get("radarr") ?? Number.NaN) }}</span>
        </div>
        <div class="app">
          <span>tdarr queue</span>
          <span class="av">{{ fmt.number(apps.data.value?.tdarr ?? Number.NaN) }}</span>
        </div>
        <div class="app">
          <span>jellyfin sessions</span>
          <span class="av">{{ fmt.number(apps.data.value?.sessions ?? Number.NaN) }}</span>
        </div>
        <div class="app">
          <span>torrent</span>
          <span
            class="av"
            :style="{
              color: (apps.data.value?.torrentState ?? 0) === 0 ? 'var(--ok)' : 'var(--warn)',
            }"
          >
            {{ TORRENT_STATE[apps.data.value?.torrentState ?? 2] ?? "unknown" }}
          </span>
        </div>
        <div class="app">
          <span>torrent rate</span>
          <span class="av">
            {{ fmt.rate(apps.data.value?.down ?? Number.NaN) }} /
            {{ fmt.rate(apps.data.value?.upRate ?? Number.NaN) }}
          </span>
        </div>
        <div class="app">
          <span>vpn exit</span>
          <span class="av">{{ apps.data.value?.vpn || "-" }}</span>
        </div>
      </div>
    </PanelBox>

  </div>
</template>

<style scoped>
.page {
  padding: 16px var(--pad-page) var(--pad-page);
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.note {
  font: var(--t-mono-sm);
  color: var(--fg-dim);
}


.rack-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
}

.counts {
  font: var(--t-mono-sm);
  color: var(--fg-5);
}


.rack {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.rack.dim {
  opacity: 0.45;
  filter: saturate(0.5);
}

.row {
  display: grid;
  grid-template-columns: 56px 148px minmax(0, 1fr) 90px 74px 128px 84px 92px;
  align-items: center;
  gap: 12px;
  padding: 10px 14px;
  border-radius: var(--r-sm);
  background: var(--row);
  border: 1px solid var(--line);
  border-left: 2px solid var(--off);
}

.row:hover {
  border-color: oklch(1 0 0 / 0.2);
}

.row.head {
  background: none;
  border: 0;
  padding: 0 14px 4px;
  font: var(--t-mono-xs);
  letter-spacing: 0.1em;
  color: var(--fg-dim);
}

.r {
  text-align: right;
}

.leds {
  display: flex;
  gap: 4px;
  align-items: center;
}

.name {
  font: var(--t-ui-md);
}

.state {
  font: var(--t-mono-xs);
  margin-top: 2px;
}

.meta {
  min-width: 0;
}

.image {
  font: var(--t-mono-sm);
  color: var(--fg-3);
}

.sub {
  display: flex;
  gap: 10px;
  margin-top: 3px;
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.num {
  text-align: right;
  font: var(--t-mono-md);
  color: var(--fg-2);
}

.dim {
  color: var(--fg-5);
  font-weight: 400;
}

.mem {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.cap {
  font: var(--t-mono-xs);
}

.unresolved {
  font: var(--t-mono-sm);
  color: var(--warn);
}







/* A strip, not a sidebar: with the topology gone there is nothing to sit
   beside, and eight facts in one column beside empty space reads as a leftover. */
.apps {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 7px 18px;
  margin-top: 8px;
}

.app {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.av {
  color: var(--fg-2);
  font-weight: 500;
}

@media (max-width: 1100px) {
  .apps {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
