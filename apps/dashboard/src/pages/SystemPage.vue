<script setup lang="ts">
/**
 * System: the findings, five core-metric cards, the pressure lanes, and the
 * four panels that answer "what is this machine doing".
 *
 * ONE TIME AXIS ACROSS EVERYTHING, which is the point of the design and is why
 * every series on this page is fetched in one pass with identical
 * start/end/step: two charts on slightly different windows cannot be read
 * against each other, and the whole reason to share an axis is to see that the
 * disk spike and the pressure spike are the same event.
 *
 * THAT STILL HOLDS NOW THAT THE LANES NO LONGER REPEAT THE CARDS. `useCrosshair`
 * is a module-level ref holding a unix TIME, not a pixel, so hovering the disk
 * card marks the same instant on the IO pressure lane below it even though they
 * are different components at different sizes. The lanes were shortened to what
 * the cards do not already draw; the cross-reading was not.
 */
import { computed, watch } from "vue";

import FindingsPanel from "@/components/FindingsPanel.vue";
import PanelBox from "@/components/PanelBox.vue";
import MetricChart from "@/components/MetricChart.vue";
import StatusDot from "@/components/StatusDot.vue";
import UptimeBars from "@/components/UptimeBars.vue";
import WindowPicker from "@/components/WindowPicker.vue";

import { usePoll } from "@/composables/usePoll";
import { useMetricsStale } from "@/composables/useStaleness";
import { useHostStore } from "@/stores/host";
import { instant, instantBy, labelsBy, range, value } from "@/api/prometheus";
import { bySeverityThenTime, fetchAlerts, isHeartbeat } from "@/api/alerts";
import { AVAILABILITY, SERVICES, SYSTEM } from "@/queries";
import { latest, onGrid, peak, sampleAt, toPoints, type ChartSeries, type Point } from "@/charts";
import { dailyRatios, ratioSummary } from "@/uptime";
import * as fmt from "@/format";
import { useTimeWindow } from "@/composables/useTimeWindow";
import { useCrosshair } from "@/composables/useCrosshair";

const host = useHostStore();
const { window: win } = useTimeWindow();
const cross = useCrosshair();

// ---------------------------------------------------------------------------
// Every range query this page draws, in one fetch on one grid.
// ---------------------------------------------------------------------------
interface Source {
  key: string;
  query: string;
  /**
   * Draw every series the query returns, one line each, keyed by this label.
   * Set only where the multiplicity is REAL and must not be collapsed: this
   * host has two GPUs, one of them with dead video engines, and taking whichever
   * series sorted first is what made the encoder read 0% for ever. The twelve
   * CPU threads are the second case, for the opposite reason - the aggregate is
   * what hides one pinned core.
   */
  splitBy?: string;
}

const SOURCES: Source[] = [
  { key: "cpuCores", query: SYSTEM.cpuPerCore, splitBy: "cpu" },
  { key: "cpuMean", query: SYSTEM.cpuBusy },
  { key: "memInUse", query: SYSTEM.memoryUsed },
  { key: "memUsed", query: SYSTEM.memoryUsedParts },
  { key: "memBuffers", query: SYSTEM.memoryBuffers },
  { key: "memCache", query: SYSTEM.memoryCache },
  { key: "memFree", query: SYSTEM.memoryFree },
  { key: "swapUsed", query: SYSTEM.swapUsed },
  { key: "netRx", query: SYSTEM.netRx },
  { key: "netTx", query: SYSTEM.netTx },
  { key: "diskRead", query: SYSTEM.diskRead },
  { key: "diskWrite", query: SYSTEM.diskWritten },
  { key: "gpu", query: SYSTEM.gpuEncoder, splitBy: "gpu" },
  { key: "iopsi", query: SYSTEM.ioPressure },
  { key: "cpupsi", query: SYSTEM.cpuPressure },
];

const series = usePoll(async (signal) => {
  const end = Math.floor(Date.now() / 1000);
  const start = end - win.value.seconds;
  const step = win.value.step;

  // THE CEILINGS ARE RESOLVED IN THE SAME PASS, deliberately. MemTotal is its
  // own instant query, and fetching it separately means the memory card scales
  // to its data on the first paint and then visibly rescales when the ceiling
  // lands - a jump on every mount, for nothing.
  const [results, memTotal, swapTotal] = await Promise.all([
    Promise.all(
      SOURCES.map(async (source) => {
        const matrix = await range(source.query, { window: win.value.seconds, step, signal });
        const split = source.splitBy;

        // Without splitBy the query aggregates in PromQL and returns exactly one
        // series, so taking the first is not a choice being made.
        const lines: Point[][] = split
          ? matrix
              .map((s) => ({
                label: s.metric[split] ?? "?",
                points: onGrid(toPoints(s.values), start, end, step),
              }))
              .sort((a, b) => a.label.localeCompare(b.label, "en", { numeric: true }))
              .map((s) => s.points)
          : [onGrid(matrix.length ? toPoints(matrix[0].values) : [], start, end, step)];

        const labels = split
          ? matrix
              .map((s) => s.metric[split] ?? "?")
              .sort((a, b) => a.localeCompare(b, "en", { numeric: true }))
          : [];

        return [source.key, { lines, labels }] as const;
      }),
    ),
    instant(SYSTEM.memoryTotal, signal).then((r) => value(r[0]?.value)),
    instant(SYSTEM.swapTotal, signal).then((r) => value(r[0]?.value)),
  ]);

  return {
    start,
    end,
    step,
    memTotal,
    swapTotal,
    by: new Map<string, { lines: Point[][]; labels: string[] }>(results),
  };
}, 30_000);

// The window is read inside the loader, so a change to it would otherwise not
// show until the next 30s tick - which reads as a dead button.
watch(win, () => {
  void series.refresh();
});

function pointsOf(key: string): Point[] {
  return series.data.value?.by.get(key)?.lines[0] ?? [];
}

function allOf(key: string): Point[][] {
  return series.data.value?.by.get(key)?.lines ?? [];
}

function labelsOf(key: string): string[] {
  return series.data.value?.by.get(key)?.labels ?? [];
}

/**
 * One number from a series: under the cursor while one is set, and the latest
 * sample otherwise - so the same slot answers "what is it now" and "what was it
 * then" without a second place to look.
 *
 * A hole reads as the no-data dash rather than as the last real value: the
 * cursor sitting in a gap must not be answered with a number from elsewhere.
 */
function at(points: Point[]): number {
  const t = cross.at.value;
  return t === null ? latest(points) : (sampleAt(points, t)?.[1] ?? Number.NaN);
}

const from = computed(() => series.data.value?.start);
const to = computed(() => series.data.value?.end);

// ---------------------------------------------------------------------------
// The five cards
// ---------------------------------------------------------------------------

/**
 * Twelve threads at one flat opacity plus the mean at full weight.
 *
 * NOT THE BRIGHTNESS RAMP: the cores are interchangeable, and drawing core 11
 * at a third of core 0 would say something about core 11 that is not true. The
 * ramp is for series that differ; these differ only in which one is busy.
 */
const cpuSeries = computed<ChartSeries[]>(() => {
  const cores = allOf("cpuCores").map((points, i) => ({
    points,
    label: `cpu${labelsOf("cpuCores")[i] ?? i}`,
    tone: "ok" as const,
    opacity: 0.3,
  }));
  const mean = pointsOf("cpuMean");
  return mean.length ? [...cores, { points: mean, label: "mean", tone: "ok" as const, opacity: 1, width: 2 }] : cores;
});

/** The busiest single thread right now. The whole reason to draw twelve lines:
 *  one core at 100% is 8% of the aggregate and looks like an idle machine. */
const busiestCore = computed(() => {
  const values = allOf("cpuCores").map((p) => at(p)).filter(Number.isFinite);
  return values.length ? Math.max(...values) : Number.NaN;
});

/**
 * Bottom band first. They sum to MemTotal by construction - see queries.ts -
 * which is the only thing that makes pinning the frame to MemTotal honest.
 */
const memorySeries = computed<ChartSeries[]>(() => [
  { points: pointsOf("memUsed"), label: "used", tone: "ok" },
  { points: pointsOf("memBuffers"), label: "buffers", tone: "ok" },
  { points: pointsOf("memCache"), label: "cache", tone: "ok" },
  { points: pointsOf("memFree"), label: "free", tone: "ok" },
]);

/** MemAvailable-based, and the aside rather than a band, because it is the
 *  number a human means by "memory in use". Reporting MemTotal - MemFree there
 *  instead would say 88% on a perfectly healthy host - the exact misreading
 *  queries.ts warns about for the same reason. */
const memoryInUse = computed(() => at(pointsOf("memInUse")));

const swap = computed(() => {
  const total = series.data.value?.swapTotal ?? Number.NaN;
  if (!Number.isFinite(total) || total <= 0) return null;
  const used = at(pointsOf("swapUsed"));
  return { used, total, ratio: used / total };
});

/** In above the zero rule, out below it. Positive magnitudes in both halves -
 *  only the drawing is signed, see charts.ts. */
const netSeries = computed<ChartSeries[]>(() => [
  { points: pointsOf("netRx"), label: "in", tone: "ok", direction: "up" },
  { points: pointsOf("netTx"), label: "out", tone: "ok", direction: "down" },
]);

const diskSeries = computed<ChartSeries[]>(() => [
  { points: pointsOf("diskRead"), label: "read", tone: "ok", direction: "up" },
  { points: pointsOf("diskWrite"), label: "write", tone: "ok", direction: "down" },
]);

// ---------------------------------------------------------------------------
// The lanes that the cards do not already draw
// ---------------------------------------------------------------------------
interface Lane {
  key: string;
  label: string;
  sub: string;
  tone: "ok" | "warn" | "fail";
  format: (v: number) => string;
  /** Pin the frame. Both pressures are a fraction of wall-clock time. */
  yMax?: number;
}

const LANES: Lane[] = [
  {
    key: "gpu",
    label: "GPU encoder",
    sub: "NVENC block, per card",
    tone: "ok",
    format: (v) => fmt.percent(v, 0),
    yMax: 1,
  },
  {
    key: "iopsi",
    label: "IO pressure",
    sub: "time fully stalled on IO",
    tone: "warn",
    format: (v) => fmt.percent(v, 1),
    yMax: 1,
  },
  {
    key: "cpupsi",
    label: "CPU pressure",
    sub: "time waiting for a core",
    tone: "warn",
    format: (v) => fmt.percent(v, 1),
    yMax: 1,
  },
];

function laneSeries(lane: Lane): ChartSeries[] {
  const entry = series.data.value?.by.get(lane.key);
  if (!entry) return [];
  return entry.lines.map((points, i) => ({
    points,
    label: entry.labels[i],
    tone: lane.tone,
  }));
}

function laneReading(lane: Lane): string {
  const lines = laneSeries(lane);
  if (!lines.length) return fmt.NO_DATA;
  return lines.map((s) => lane.format(at(s.points))).join(" / ");
}

function lanePeak(lane: Lane): string {
  const lines = laneSeries(lane);
  if (!lines.length) return fmt.NO_DATA;
  return lines.map((s) => lane.format(peak(s.points))).join(" / ");
}

/** Seven ticks across the window, each carrying the date only where it changes -
 *  without which every tick on the 7d window is a bare HH:MM naming no day. */
const axis = computed(() => {
  const s = series.data.value;
  if (!s) return [];
  return fmt.axisTicks(s.start, s.end, 7);
});

/** What the value column is currently reporting, named in its header. */
const cursorStamp = computed(() => (cross.at.value === null ? null : fmt.stamp(cross.at.value)));

// ---------------------------------------------------------------------------
// Alerts, which is where the design's log stream was. See src/api/alerts.ts.
// ---------------------------------------------------------------------------
const alerts = usePoll((signal) => fetchAlerts(signal), 30_000);

/** The heartbeat is NOT one of these. It always fires, so listing it puts a
 *  permanent amber row above every real alert and makes "4 firing" mean three. */
const sortedAlerts = computed(() =>
  [...(alerts.data.value ?? [])].filter((a) => !isHeartbeat(a)).sort(bySeverityThenTime),
);

/**
 * HIDING IT MUST NOT HIDE ITS ABSENCE, which is the only thing it ever had to
 * say. `expr: vector(1)` cannot stop firing while Prometheus evaluates rules
 * and Alertmanager holds them, so a response that does not contain it is the
 * chain being broken - the finding the rule exists to produce.
 *
 * Guarded on there being a response at all: Alertmanager unreachable already
 * dims this panel with its own sentence, and must not additionally be reported
 * as a dead heartbeat.
 */
const heartbeatLost = computed(
  () =>
    alerts.error.value === null &&
    alerts.data.value !== null &&
    !alerts.data.value.some(isHeartbeat),
);

/** Event ticks on the shared axis: where each active alert began. Alerts that
 *  started before the window are pinned to the left edge rather than dropped -
 *  "has been firing since before this view" is worth seeing. */
const eventMarks = computed(() => {
  const s = series.data.value;
  if (!s) return [];
  return sortedAlerts.value.map((a) => {
    const t = Date.parse(a.startsAt) / 1000;
    const ratio = Math.min(1, Math.max(0, (t - s.start) / (s.end - s.start)));
    return {
      key: a.fingerprint ?? a.labels.alertname,
      left: `${(ratio * 100).toFixed(2)}%`,
      tone: a.labels.severity === "critical" ? ("fail" as const) : ("warn" as const),
      before: t < s.start,
    };
  });
});

// ---------------------------------------------------------------------------
// Drives, filesystems and SMART
// ---------------------------------------------------------------------------
const storage = usePoll(async (signal) => {
  const [info, health, temp, hours, wear, realloc, pending, size, avail] = await Promise.all([
    labelsBy(SYSTEM.disksInfo, "device", signal),
    instantBy(SYSTEM.diskHealth, "device", signal),
    instantBy(SYSTEM.diskTemp, "device", signal),
    instantBy(SYSTEM.diskHours, "device", signal),
    instantBy(SYSTEM.diskWear, "device", signal),
    instantBy(SYSTEM.diskReallocated, "device", signal),
    instantBy(SYSTEM.diskPending, "device", signal),
    instant(SYSTEM.filesystems, signal),
    instantBy(SYSTEM.filesystemAvail, "mountpoint", signal),
  ]);

  const filesystems = size.map((s) => {
    const mountpoint = s.metric.mountpoint ?? "?";
    const total = value(s.value);
    const free = avail.get(mountpoint) ?? Number.NaN;
    return { mountpoint, device: s.metric.device ?? "", total, free, used: total - free, ratio: 1 - free / total };
  });

  const drives = [...info.entries()].map(([device, labels]) => ({
    device,
    model: labels.model ?? "",
    healthy: health.get(device) === 1,
    temp: temp.get(device) ?? Number.NaN,
    hours: hours.get(device) ?? Number.NaN,
    wear: wear.get(device) ?? Number.NaN,
    realloc: realloc.get(device) ?? Number.NaN,
    pending: pending.get(device) ?? Number.NaN,
  }));

  return { drives, filesystems };
}, 60_000);

/** SMART in one line per drive: the thing that changed, or that nothing has. */
function smartLine(d: { healthy: boolean; realloc: number; pending: number; wear: number }): {
  text: string;
  tone: "ok" | "warn" | "fail";
} {
  if (!d.healthy) return { text: "SMART reports the drive as failing", tone: "fail" };
  if (Number.isFinite(d.pending) && d.pending > 0) {
    return { text: `${d.pending} pending sector(s)`, tone: "fail" };
  }
  if (Number.isFinite(d.realloc) && d.realloc > 0) {
    return { text: `${d.realloc} reallocated sector(s)`, tone: "warn" };
  }
  if (Number.isFinite(d.wear)) return { text: `${fmt.percent(d.wear, 0)} of rated write endurance used`, tone: "ok" };
  return { text: "no reallocated or pending sectors", tone: "ok" };
}

function fsTone(ratio: number): "ok" | "warn" | "fail" {
  if (!Number.isFinite(ratio)) return "ok";
  if (ratio >= 0.95) return "fail";
  if (ratio >= 0.85) return "warn";
  return "ok";
}

// ---------------------------------------------------------------------------
// Thirty days of availability, and the backup ages
// ---------------------------------------------------------------------------
const AVAILABILITY_ROWS = 5;

const availability = usePoll(async (signal) => {
  // An HOURLY step, deliberately: dailyRatios buckets into local days and needs
  // samples inside them to do it. See the comment on the query itself.
  const matrix = await range(AVAILABILITY.containerHourly, { window: 30 * 86400, step: 3600, signal });

  return matrix
    .map((s) => {
      const days = dailyRatios(toPoints(s.values), 30);
      const known = days.filter(Number.isFinite);
      const worst = known.length ? Math.min(...known) : 1;
      return { name: s.metric.container ?? "?", days, worst, summary: ratioSummary(days) };
    })
    // Worst first: a strip of five perfect rows tells you nothing, and the
    // one that dipped is the only reason to look.
    .sort((a, b) => a.worst - b.worst)
    .slice(0, AVAILABILITY_ROWS);
}, 300_000);

const backups = computed(() => [
  { label: "local", key: "backup_local_at", limit: 48 * 3600 },
  { label: "off-site", key: "backup_offsite_at", limit: 72 * 3600 },
  { label: "policy proof", key: "backup_offsite_policy_ok_at", limit: 48 * 3600 },
  { label: "off-site prune", key: "backup_offsite_pruned_at", limit: 30 * 86400 },
]);

function backupTone(key: string, limit: number): "ok" | "warn" | "fail" | "off" {
  const age = host.factAge(key);
  if (!Number.isFinite(age)) return "off";
  return age > limit ? "fail" : age > limit * 0.75 ? "warn" : "ok";
}

// ---------------------------------------------------------------------------
// Staleness, passed down to every panel rather than decided inside them
// ---------------------------------------------------------------------------
// useMetricsStale lives in @/composables/useStaleness: four pages need the same
// sentence, and four copies is how they start disagreeing. The battery half of
// it went with the findings, into FindingsPanel.
const metricsStale = useMetricsStale();

const osLine = computed(() => {
  const booted = host.fact("booted_version");
  const uptime = host.numericFact("uptime_s");
  const parts = [booted ? `uCore ${booted}` : null, Number.isFinite(uptime) ? `up ${fmt.duration(uptime)}` : null];
  return parts.filter(Boolean).join(" / ") || "host unknown";
});

const staged = computed(() => {
  const s = host.fact("staged_version");
  return typeof s === "string" && s.length ? s : null;
});

// The GPU is worth a panel of its own: two NVENC sessions already pin the
// encoder block at 100% while the SM sits at 10%, so "the GPU is busy" and
// "the GPU is saturated" are different questions here.
//
// A COLUMN PER CARD, because this host has two and they are not interchangeable:
// GPU 0's video engines are dead hardware, which the quadlets work around by
// pinning both consumers to nvidia.com/gpu=1. Reading `[0]` off each of these
// answered for the idle card - and instant-vector order is not guaranteed by the
// API anyway, so the four rows could each have described a different one.
const gpu = usePoll(async (signal) => {
  const [encoder, sm, temp, power, sessions] = await Promise.all([
    instantBy(SYSTEM.gpuEncoder, "gpu", signal),
    instantBy(SYSTEM.gpuSm, "gpu", signal),
    instantBy(SYSTEM.gpuTemp, "gpu", signal),
    instantBy(SYSTEM.gpuPower, "gpu", signal),
    instantBy(SYSTEM.gpuSessions, "gpu", signal),
  ]);

  const cards = [...new Set([...encoder.keys(), ...temp.keys(), ...power.keys()])].sort((a, b) =>
    a.localeCompare(b, "en", { numeric: true }),
  );

  return cards.map((id) => ({
    id,
    encoder: encoder.get(id) ?? Number.NaN,
    sm: sm.get(id) ?? Number.NaN,
    temp: temp.get(id) ?? Number.NaN,
    power: power.get(id) ?? Number.NaN,
    sessions: sessions.get(id) ?? Number.NaN,
  }));
}, 30_000);

/** Rows of the GPU table, so the template does not repeat the per-card map five
 *  times. `of 8` stays on the sessions row: that ceiling is per card. */
const GPU_ROWS: { label: string; read: (c: GpuCard) => string }[] = [
  { label: "encoder", read: (c) => fmt.percent(c.encoder, 0) },
  { label: "SM", read: (c) => fmt.percent(c.sm, 0) },
  { label: "NVENC sessions", read: (c) => `${fmt.number(c.sessions)} of 8` },
  { label: "temperature", read: (c) => fmt.celsius(c.temp) },
  { label: "board power", read: (c) => fmt.watts(c.power) },
];

interface GpuCard {
  id: string;
  encoder: number;
  sm: number;
  temp: number;
  power: number;
  sessions: number;
}

const jellyfinSessions = usePoll(
  async (signal) => value((await instant(SERVICES.jellyfinSessions, signal))[0]?.value),
  30_000,
);
</script>

<template>
  <div class="page">
    <Teleport defer to="#toolbar">
      <span class="mono os">{{ osLine }}</span>
      <span v-if="staged" class="staged mono">{{ staged }} staged</span>

      <WindowPicker />
    </Teleport>

    <!-- The findings, in the one place they live. See FindingsPanel.vue for
         why there is no longer a second, differently-coloured copy of this. -->
    <FindingsPanel />

    <!-- The five cards. Core vitals only: the GPU is a detail of one workload
         and has a panel of its own below. -->
    <section class="section">
      <div class="head">
        <span class="label">Core metrics</span>
        <span class="label right" :class="{ at: cursorStamp }">{{ cursorStamp ?? "Current" }}</span>
      </div>

      <div class="cards">
        <PanelBox class="c-cpu" label="CPU" :stale="metricsStale">
          <template #aside>
            <span class="value mono" :class="{ hovered: cross.active.value }">
              {{ fmt.percent(at(pointsOf("cpuMean")), 1) }}
            </span>
          </template>
          <MetricChart
            :series="cpuSeries"
            :height="104"
            :grid="4"
            :y-max="1"
            y-axis
            x-axis
            :x-ticks="5"
            :format="(v: number) => fmt.percent(v, 0)"
            :from="from"
            :to="to"
          />
          <div class="foot mono">
            <span>12 threads, busy fraction of each</span>
            <span>busiest thread {{ fmt.percent(busiestCore, 0) }}</span>
          </div>
        </PanelBox>

        <PanelBox class="c-mem" label="Memory" :stale="metricsStale">
          <template #aside>
            <span class="value mono" :class="{ hovered: cross.active.value }">
              {{ fmt.bytes(memoryInUse) }}
            </span>
          </template>
          <MetricChart
            :series="memorySeries"
            :height="104"
            :grid="4"
            :y-max="series.data.value?.memTotal"
            stacked
            legend
            y-axis
            x-axis
            :x-ticks="4"
            :tick-base="1024"
            :format="(v: number) => fmt.bytes(v, 0)"
            :from="from"
            :to="to"
          />
          <!-- SWAP IS NOT A FIFTH BAND. The stack is pinned to MemTotal and
               adding four gigabytes to it would draw a machine with twenty. -->
          <div v-if="swap" class="swap">
            <div class="swap-head mono">
              <span>swap</span>
              <span>{{ fmt.bytes(swap.used) }} of {{ fmt.bytes(swap.total) }}</span>
            </div>
            <div class="bar">
              <span class="fill" :style="{ width: `${Math.min(100, swap.ratio * 100).toFixed(1)}%` }" />
            </div>
          </div>
        </PanelBox>

        <PanelBox class="c-net" label="Network" :stale="metricsStale">
          <template #aside>
            <span class="value mono" :class="{ hovered: cross.active.value }">
              {{ fmt.rate(at(pointsOf("netRx"))) }}
            </span>
          </template>
          <MetricChart
            :series="netSeries"
            :height="88"
            :grid="4"
            mirror
            y-axis
            x-axis
            :x-ticks="3"
            :tick-base="1024"
            :format="(v: number) => fmt.rate(v)"
            :from="from"
            :to="to"
          />
          <div class="foot mono">
            <span>in, above / out, below</span>
            <span>out {{ fmt.rate(at(pointsOf("netTx"))) }}</span>
          </div>
        </PanelBox>

        <PanelBox class="c-disk" label="Disk I/O" :stale="metricsStale">
          <template #aside>
            <span class="value mono" :class="{ hovered: cross.active.value }">
              {{ fmt.rate(at(pointsOf("diskRead"))) }}
            </span>
          </template>
          <MetricChart
            :series="diskSeries"
            :height="88"
            :grid="4"
            mirror
            y-axis
            x-axis
            :x-ticks="3"
            :tick-base="1024"
            :format="(v: number) => fmt.rate(v)"
            :from="from"
            :to="to"
          />
          <div class="foot mono">
            <span>read, above / write, below</span>
            <span>write {{ fmt.rate(at(pointsOf("diskWrite"))) }}</span>
          </div>
        </PanelBox>

        <PanelBox class="c-fs" label="Disk usage" :stale="metricsStale">
          <template #aside>
            <span>{{ (storage.data.value?.filesystems ?? []).length }} mounts</span>
          </template>
          <div class="filesystems">
            <div v-for="f in storage.data.value?.filesystems ?? []" :key="f.mountpoint" class="fs">
              <div class="fs-head">
                <span class="mono">{{ f.mountpoint }}</span>
                <span class="mono dim">{{ fmt.bytes(f.free) }} free</span>
              </div>
              <div class="bar">
                <span
                  class="fill"
                  :style="{ width: `${Math.min(100, f.ratio * 100).toFixed(1)}%`, background: `var(--${fsTone(f.ratio)})` }"
                />
              </div>
              <div class="fs-foot mono">
                <span>{{ fmt.bytes(f.used) }} of {{ fmt.bytes(f.total) }}</span>
                <span :style="{ color: `var(--${fsTone(f.ratio)})` }">{{ fmt.percent(f.ratio, 0) }}</span>
              </div>
            </div>
          </div>
        </PanelBox>
      </div>
    </section>

    <!-- What the cards do not draw, on the same axis they are drawn on. -->
    <section class="section">
      <div class="head">
        <span class="label">Pressure and events</span>
      </div>

      <div class="timeline">
        <header class="tl-head">
          <span class="label">Lane</span>
          <div class="tl-axis mono">
            <!-- The day slot is always rendered, empty where the date has not
                 changed, so the times stay on one baseline across the row. -->
            <span v-for="(t, i) in axis" :key="i" class="tick">
              <span class="tick-day">{{ t.day ?? "" }}</span>
              <span>{{ i === axis.length - 1 ? "now" : t.time }}</span>
            </span>
          </div>
          <span class="label right">Reading</span>
        </header>

        <!-- Dimmed on the same signal as the cards above, which are fetched in
             the same pass. The Alerts lane below is NOT dimmed: it comes from
             Alertmanager, which is a different source with a different pulse. -->
        <div v-for="lane in LANES" :key="lane.key" class="lane" :class="{ dim: !!metricsStale }">
          <div class="lane-name">
            <div class="lane-label">{{ lane.label }}</div>
            <div class="lane-sub mono">{{ lane.sub }}</div>
          </div>
          <MetricChart
            :series="laneSeries(lane)"
            :tone="lane.tone"
            :height="30"
            :y-max="lane.yMax"
            :format="lane.format"
            :from="from"
            :to="to"
          />
          <div class="lane-value">
            <span class="mono now" :style="{ color: `var(--${lane.tone})` }">
              {{ laneReading(lane) }}
            </span>
            <div class="lane-peak mono">peak {{ lanePeak(lane) }}</div>
          </div>
        </div>

        <div class="lane">
          <div class="lane-name">
            <div class="lane-label">Alerts</div>
            <div class="lane-sub mono">when each one started</div>
          </div>
          <div class="events">
            <span
              v-for="m in eventMarks"
              :key="m.key"
              class="mark"
              :class="{ before: m.before }"
              :style="{ left: m.left }"
            >
              <span class="stem" :style="{ background: `var(--${m.tone})` }" />
              <StatusDot :tone="m.tone" glow :size="7" />
            </span>
            <span class="sweep" />
          </div>
          <div class="lane-value">
            <span class="mono now">{{ eventMarks.length }}</span>
            <div class="lane-peak mono">firing</div>
          </div>
        </div>
      </div>
    </section>

    <!-- Bottom row -->
    <section class="section">
      <div class="head">
        <span class="label">Storage and history</span>
      </div>

      <div class="bottom">
        <PanelBox label="GPU and playback" :stale="metricsStale">
          <div
            v-if="gpu.data.value?.length"
            class="gpu mono"
            :style="{ '--cards': gpu.data.value.length }"
          >
            <div class="gpu-row head-row">
              <span></span>
              <span v-for="c in gpu.data.value" :key="c.id" class="gv">gpu{{ c.id }}</span>
            </div>
            <div v-for="row in GPU_ROWS" :key="row.label" class="gpu-row">
              <span>{{ row.label }}</span>
              <span v-for="c in gpu.data.value" :key="c.id" class="gv">{{ row.read(c) }}</span>
            </div>
            <div class="gpu-row">
              <span>Jellyfin sessions</span>
              <span class="gv span-all">{{ fmt.number(jellyfinSessions.data.value ?? Number.NaN) }}</span>
            </div>
          </div>
          <p v-else class="empty mono">no GPU reported</p>
          <p class="note mono">
            Two NVENC sessions already pin the encoder block at 100% while the SM sits near 10%, so a
            third GPU worker cannot encode faster. gpu0's video engines are dead hardware, so both
            consumers are pinned to gpu1 and gpu0 encodes nothing by design.
          </p>
        </PanelBox>

        <PanelBox label="Alerts" sunken :stale="alerts.error.value ? 'alertmanager could not be reached' : null">
          <template #aside>
            <span>{{ sortedAlerts.length }} firing</span>
          </template>

          <ul v-if="sortedAlerts.length" class="alerts">
            <li v-for="a in sortedAlerts" :key="a.fingerprint ?? a.labels.alertname" class="alert">
              <div class="alert-head">
                <StatusDot :tone="a.labels.severity === 'critical' ? 'fail' : 'warn'" :size="5" />
                <span class="alert-name mono">{{ a.labels.alertname }}</span>
                <span class="alert-age mono">{{ fmt.sinceIso(a.startsAt, host.now) }}</span>
              </div>
              <div class="alert-summary">{{ a.annotations.summary ?? "" }}</div>
              <div class="alert-detail mono truncate" :title="a.annotations.description">
                {{ a.annotations.description ?? "" }}
              </div>
            </li>
          </ul>
          <p v-else class="empty mono">nothing firing</p>

          <!-- The heartbeat is hidden while it is alive, because firing IS the
               healthy state. Its absence is the finding, and it is the only
               thing this rule was ever able to say. -->
          <p v-if="heartbeatLost" class="note lost mono">
            The alerting heartbeat is not firing, so the notification chain is unproven. Check
            alertmanager, then ntfy-alertmanager, then ntfy, in that order.
          </p>
        </PanelBox>

        <div class="right-column">
          <PanelBox label="Drives and SMART" :stale="metricsStale">
            <div class="drives">
              <div v-for="d in storage.data.value?.drives ?? []" :key="d.device" class="drive">
                <div class="drive-head">
                  <span class="mono dev">{{ d.device }}</span>
                  <span class="mono model truncate" :title="d.model">{{ d.model }}</span>
                </div>
                <div class="drive-grid mono">
                  <span>{{ fmt.celsius(d.temp) }}</span>
                  <span class="right">{{ fmt.powerOnHours(d.hours) }}</span>
                </div>
                <div class="smart mono" :class="smartLine(d).tone">{{ smartLine(d).text }}</div>
              </div>
            </div>
          </PanelBox>

          <PanelBox label="Uptime, 30 days" :stale="metricsStale">
            <template #aside>
              <span>worst five</span>
            </template>

            <div class="uptime">
              <div v-for="row in availability.data.value ?? []" :key="row.name" class="uprow">
                <div class="uphead mono">
                  <span>{{ row.name }}</span>
                  <span :style="{ color: row.worst < 0.999 ? 'var(--warn)' : 'var(--ok)' }">{{ row.summary }}</span>
                </div>
                <UptimeBars :days="row.days" />
              </div>
            </div>

            <div class="backups">
              <div v-for="b in backups" :key="b.key" class="backup mono">
                <StatusDot :tone="backupTone(b.key, b.limit)" :size="5" />
                <span class="bname">{{ b.label }}</span>
                <span class="bage">{{ fmt.sinceIso(host.fact(b.key) as string, host.now) }}</span>
              </div>
            </div>
          </PanelBox>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
/* Two rhythms, not one. --gap-lg between sections and --gap inside them is what
   makes this read as four sections rather than as one stack of panels. */
.page {
  padding: 16px var(--pad-page) var(--pad-page);
  display: flex;
  flex-direction: column;
  gap: var(--gap-lg);
}

.section {
  display: flex;
  flex-direction: column;
  gap: var(--gap);
  min-width: 0;
}

.head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
}

.os {
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.staged {
  font: var(--t-mono-sm);
  color: var(--warn);
  padding: 4px 9px;
  border-radius: var(--r-xs);
  background: var(--warn-tint);
  border: 1px solid var(--warn-edge);
}

/* --- the cards --------------------------------------------------------- */
/* Twelve columns, because the two rows do not divide the same way: CPU needs
   the width for twelve lines, and the second row is three equal things. */
.cards {
  display: grid;
  grid-template-columns: repeat(12, 1fr);
  gap: var(--gap);
  align-items: start;
}

.c-cpu {
  grid-column: span 7;
}

.c-mem {
  grid-column: span 5;
}

.c-net,
.c-disk,
.c-fs {
  grid-column: span 4;
}

.value {
  font: var(--t-mono-lg);
  color: var(--fg);
}

/* Says the number is a reading from the cursor rather than the live one, so a
   frozen-looking figure is never mistaken for the current value. */
.value.hovered {
  color: var(--ok);
}

.foot {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  margin-top: 8px;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.swap {
  margin-top: 10px;
  padding-top: 9px;
  border-top: 1px solid var(--line);
}

.swap-head {
  display: flex;
  justify-content: space-between;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.filesystems {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

/* --- timeline ----------------------------------------------------------- */
.tl-head,
.lane {
  display: grid;
  grid-template-columns: 160px 1fr 128px;
  gap: 0 16px;
  align-items: center;
}

.tl-head {
  padding-bottom: 8px;
  border-bottom: 1px solid var(--line);
}

.tl-axis {
  display: flex;
  justify-content: space-between;
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.tick {
  display: flex;
  flex-direction: column;
  align-items: center;
  line-height: 1.35;
}

/* Brighter than the time it sits above: the date is the rarer, more orienting
   half. Empty on most ticks, where it only holds the baseline. */
.tick-day {
  color: var(--fg-4);
  min-height: 1.35em;
}

/* A timestamp is not a heading: it keeps its own case and its own figures. */
.at {
  color: var(--ok);
  text-transform: none;
  font: var(--t-mono-xs);
  white-space: nowrap;
}

.right {
  text-align: right;
}

.lane {
  padding: 8px 0;
  border-bottom: 1px solid var(--line-faint);
}

.lane:hover {
  background: oklch(1 0 0 / 0.025);
}

.lane.dim {
  opacity: 0.4;
  filter: saturate(0.5);
}

.lane-label {
  font: var(--t-ui-md);
  color: var(--fg-2);
}

.lane-sub {
  font: var(--t-mono-xs);
  color: var(--fg-5);
  margin-top: 3px;
}

.lane-value {
  text-align: right;
}

.now {
  font: var(--t-mono-lg);
}

.lane-peak {
  font: var(--t-mono-xs);
  color: var(--fg-5);
  margin-top: 3px;
}

.events {
  position: relative;
  height: 32px;
  border-radius: var(--r-sm);
  background: var(--surface);
  border: 1px solid var(--line);
  overflow: hidden;
}

.mark {
  position: absolute;
  top: 0;
  bottom: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 3px;
  transform: translateX(-50%);
}

.mark.before {
  opacity: 0.5;
}

.stem {
  width: 2px;
  height: 11px;
}

/* FULL WIDTH, with the band painted inside it as a background. It used to be a
   60px element translated by percentages of ITSELF, so it crossed 252px of a
   1200px lane and looped there. Now translateX(100%) is one whole lane. */
.sweep {
  position: absolute;
  inset: 0;
  background: linear-gradient(90deg, transparent, var(--ok-tint), transparent);
  background-size: var(--sweep-band) 100%;
  background-repeat: no-repeat;
  animation: sweep 6s linear infinite;
  pointer-events: none;
}

/* --- bottom ------------------------------------------------------------- */
.bottom {
  display: grid;
  grid-template-columns: 1fr 1fr 340px;
  gap: var(--gap);
  align-items: start;
}

.right-column {
  display: flex;
  flex-direction: column;
  gap: var(--gap);
  min-width: 0;
}

.empty {
  font: var(--t-mono-sm);
  color: var(--fg-dim);
  padding: 6px 4px;
}

.note {
  margin-top: 10px;
  padding-top: 9px;
  border-top: 1px solid var(--line);
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.note.lost {
  color: var(--fail-text);
}

.alerts {
  display: flex;
  flex-direction: column;
  gap: 10px;
  max-height: 320px;
  overflow-y: auto;
}

.alert-head {
  display: flex;
  align-items: center;
  gap: 8px;
}

.alert-name {
  font: var(--t-mono-md);
  color: var(--fg-2);
}

.alert-age {
  margin-left: auto;
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.alert-summary {
  font: var(--t-ui-sm);
  color: var(--fg-3);
  margin-top: 3px;
}

.alert-detail {
  font: var(--t-mono-xs);
  color: var(--fg-5);
  margin-top: 2px;
}

/* --- drives ------------------------------------------------------------- */
.drives {
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.drive-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 10px;
}

.dev {
  font: var(--t-mono-md);
}

.model {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.drive-grid {
  display: flex;
  justify-content: space-between;
  font: var(--t-mono-sm);
  color: var(--fg-5);
  margin-top: 6px;
}

.smart {
  margin-top: 7px;
  padding: 6px 8px;
  border-radius: var(--r-xs);
  font: var(--t-mono-sm);
  background: var(--fill);
  color: var(--fg-3);
}

.smart.warn {
  background: var(--warn-tint);
  color: var(--warn);
}

.smart.fail {
  background: var(--fail-tint);
  color: var(--fail-text);
}

.fs-head,
.fs-foot {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  font: var(--t-mono-sm);
  color: var(--fg-3);
}

.dim {
  color: var(--fg-5);
}

.bar {
  height: 6px;
  border-radius: 3px;
  background: var(--track);
  overflow: hidden;
  margin: 7px 0;
}

.fill {
  display: block;
  height: 100%;
  background: var(--ok);
}

.fs-foot {
  color: var(--fg-5);
}

/* --- uptime ------------------------------------------------------------- */
.uptime {
  display: flex;
  flex-direction: column;
  gap: 9px;
}

.uphead {
  display: flex;
  justify-content: space-between;
  font: var(--t-mono-sm);
  color: var(--fg-3);
  margin-bottom: 5px;
}

.backups {
  margin-top: 12px;
  padding-top: 11px;
  border-top: 1px solid var(--line);
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.backup {
  display: flex;
  align-items: center;
  gap: 8px;
  font: var(--t-mono-sm);
}

.bname {
  color: var(--fg-3);
}

.bage {
  margin-left: auto;
  color: var(--fg-5);
}

/* --- gpu ---------------------------------------------------------------- */
.gpu {
  display: flex;
  flex-direction: column;
  gap: 7px;
}

/* A column per card, sized from --cards, so a one-GPU host renders the same
   table rather than a special case. */
.gpu-row {
  display: grid;
  grid-template-columns: 1fr repeat(var(--cards, 1), minmax(0, auto));
  gap: 0 12px;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.gpu-row.head-row {
  color: var(--fg-dim);
  font: var(--t-mono-xs);
}

.gv {
  color: var(--fg-2);
  font-weight: 500;
  text-align: right;
}

.gpu-row.head-row .gv {
  color: var(--fg-dim);
  font-weight: 400;
}

/* Not a per-card number - it belongs to Jellyfin, not to a card. */
.span-all {
  grid-column: 2 / -1;
}

@media (max-width: 1280px) {
  .cards > * {
    grid-column: 1 / -1;
  }

  .bottom {
    grid-template-columns: 1fr 1fr;
  }

  .right-column {
    grid-column: 1 / -1;
    flex-direction: row;
  }

  .right-column > * {
    flex: 1;
  }
}
</style>
