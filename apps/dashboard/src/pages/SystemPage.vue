<script setup lang="ts">
/**
 * System: the actionable strip, three headline charts, one shared timeline,
 * and the four panels that answer "what is this machine doing".
 *
 * The shared time axis across every lane is the point of the design, and it is
 * why all six lanes are fetched in one pass with identical start/end/step: two
 * charts on slightly different windows cannot be read against each other, and
 * the whole reason to put them on one axis is to see that the disk spike and
 * the pressure spike are the same event.
 */
import { computed, watch } from "vue";

import PanelBox from "@/components/PanelBox.vue";
import MetricChart from "@/components/MetricChart.vue";
import StatusDot from "@/components/StatusDot.vue";
import UptimeBars from "@/components/UptimeBars.vue";

import { usePoll } from "@/composables/usePoll";
import { useHostStore } from "@/stores/host";
import { instant, instantBy, labelsBy, range, value } from "@/api/prometheus";
import { bySeverityThenTime, fetchAlerts } from "@/api/alerts";
import { AVAILABILITY, SERVICES, SYSTEM } from "@/queries";
import { latest, onGrid, peak, toPoints, type Point } from "@/charts";
import { dailyRatios, ratioSummary } from "@/uptime";
import * as fmt from "@/format";
import { useTimeWindow } from "@/composables/useTimeWindow";

const host = useHostStore();
const { window: win, windows, setWindow, active } = useTimeWindow();

// ---------------------------------------------------------------------------
// The lanes. One definition drives the shared timeline AND the three headline
// charts above it, so the two can never disagree about what they are showing.
// ---------------------------------------------------------------------------
interface Lane {
  key: string;
  label: string;
  sub: string;
  query: string;
  tone: "ok" | "warn" | "fail";
  unit: string;
  format: (v: number) => string;
  /** Shown as one of the three big charts at the top. */
  headline?: boolean;
  floorAtZero?: boolean;
}

const LANES: Lane[] = [
  {
    key: "cpu",
    label: "CPU",
    sub: "all cores, busy fraction",
    query: SYSTEM.cpuBusy,
    tone: "ok",
    unit: "",
    format: (v) => fmt.percent(v, 1),
    headline: true,
  },
  {
    key: "memory",
    label: "Memory",
    sub: "in use, MemAvailable based",
    query: SYSTEM.memoryUsed,
    tone: "ok",
    unit: "",
    format: (v) => fmt.bytes(v),
    headline: true,
  },
  {
    key: "gpu",
    label: "GPU encoder",
    sub: "NVENC block, not the SM",
    query: SYSTEM.gpuEncoder,
    tone: "ok",
    unit: "",
    format: (v) => fmt.percent(v, 0),
    headline: true,
  },
  {
    key: "net",
    label: "Network in",
    sub: "physical interfaces",
    query: SYSTEM.netRx,
    tone: "ok",
    unit: "",
    format: (v) => fmt.rate(v),
  },
  {
    key: "disk",
    label: "Disk read",
    sub: "every block device",
    query: SYSTEM.diskRead,
    tone: "ok",
    unit: "",
    format: (v) => fmt.rate(v),
  },
  {
    key: "iopsi",
    label: "IO pressure",
    sub: "time fully stalled on IO",
    query: SYSTEM.ioPressure,
    tone: "warn",
    unit: "",
    format: (v) => fmt.percent(v, 1),
  },
  {
    key: "cpupsi",
    label: "CPU pressure",
    sub: "time waiting for a core",
    query: SYSTEM.cpuPressure,
    tone: "warn",
    unit: "",
    format: (v) => fmt.percent(v, 1),
  },
];

const series = usePoll(async (signal) => {
  const end = Math.floor(Date.now() / 1000);
  const start = end - win.value.seconds;
  const step = win.value.step;

  const results = await Promise.all(
    LANES.map(async (lane) => {
      const matrix = await range(lane.query, { window: win.value.seconds, step, signal });
      const points = matrix.length ? toPoints(matrix[0].values) : [];
      return [lane.key, onGrid(points, start, end, step)] as const;
    }),
  );

  return { start, end, step, byLane: new Map<string, Point[]>(results) };
}, 30_000);

// The window is read inside the loader, so a change to it would otherwise not
// show until the next 30s tick - which reads as a dead button.
watch(win, () => {
  void series.refresh();
});

function points(key: string): Point[] {
  return series.data.value?.byLane.get(key) ?? [];
}

const headlines = computed(() => LANES.filter((l) => l.headline));

/** Six evenly spaced wall-clock ticks across the window, plus "now". */
const axis = computed(() => {
  const s = series.data.value;
  if (!s) return [];
  const ticks: string[] = [];
  for (let i = 0; i < 6; i += 1) {
    ticks.push(fmt.clock(s.start + ((s.end - s.start) * i) / 6));
  }
  return [...ticks, "now"];
});

// ---------------------------------------------------------------------------
// Alerts, which is where the design's log stream was. See src/api/alerts.ts.
// ---------------------------------------------------------------------------
const alerts = usePoll((signal) => fetchAlerts(signal), 30_000);
const sortedAlerts = computed(() => [...(alerts.data.value ?? [])].sort(bySeverityThenTime));

/** Event ticks on the shared axis: where each active alert began. Alerts that
 *  started before the window are pinned to the left edge rather than dropped -
 *  "has been firing since before this view" is worth seeing. */
const eventMarks = computed(() => {
  const s = series.data.value;
  if (!s) return [];
  return sortedAlerts.value.map((a) => {
    const at = Date.parse(a.startsAt) / 1000;
    const ratio = Math.min(1, Math.max(0, (at - s.start) / (s.end - s.start)));
    return {
      key: a.fingerprint ?? a.labels.alertname,
      left: `${(ratio * 100).toFixed(2)}%`,
      tone: a.labels.severity === "critical" ? ("fail" as const) : ("warn" as const),
      before: at < s.start,
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
  const matrix = await range(AVAILABILITY.containerDaily, { window: 30 * 86400, step: 86400, signal });

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
const metricsStale = computed(() => {
  if (host.prometheusDown) return "prometheus is unreachable; this is the last answer it gave";
  const f = host.collectorFreshness;
  if (f.missing) return "the collector has never reported";
  if (f.stale) return `the collector last ran ${fmt.duration(f.age)} ago; these numbers are frozen`;
  return null;
});

const batteryStale = computed(() => {
  if (host.statusNeverRun) return "the check battery has never run on this host";
  const f = host.statusFreshness;
  if (f.missing) return "status.json could not be read";
  if (f.stale) return `the battery last ran ${fmt.duration(f.age)} ago`;
  return null;
});

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

// The GPU is worth a line of its own: two NVENC sessions already pin the
// encoder block at 100% while the SM sits at 10%, so "the GPU is busy" and
// "the GPU is saturated" are different questions here.
const gpu = usePoll(async (signal) => {
  const [temp, power, sessions] = await Promise.all([
    instant(SYSTEM.gpuTemp, signal),
    instant(SYSTEM.gpuPower, signal),
    instant(SYSTEM.gpuSessions, signal),
  ]);
  return {
    temp: value(temp[0]?.value),
    power: value(power[0]?.value),
    sessions: value(sessions[0]?.value),
  };
}, 30_000);

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

      <div class="picker">
        <button
          v-for="w in windows"
          :key="w.id"
          class="pick mono"
          :class="{ on: active === w.id }"
          @click="setWindow(w.id)"
        >
          {{ w.label }}
        </button>
      </div>
    </Teleport>

    <!-- The actionable strip. Only non-passing findings, worst first, capped
         at three - the design's whole argument is that this row is glanceable,
         and the full list is the panel below. -->
    <section v-if="host.problems.length" class="strip">
      <article v-for="c in host.problems.slice(0, 3)" :key="c.id" class="finding" :class="c.status">
        <StatusDot :tone="c.status === 'fail' ? 'fail' : 'warn'" :live="c.status === 'fail'" :size="6" />
        <div class="finding-body">
          <div class="finding-title">{{ c.message }}</div>
          <div class="finding-id mono">{{ c.id }}</div>
        </div>
      </article>
    </section>

    <!-- Three headline charts -->
    <section class="headlines">
      <PanelBox v-for="lane in headlines" :key="lane.key" :label="lane.label" :stale="metricsStale">
        <template #aside>
          <span class="value mono">{{ lane.format(latest(points(lane.key))) }}</span>
        </template>
        <MetricChart
          :points="points(lane.key)"
          :tone="lane.tone"
          :height="72"
          :grid="3"
          show-median
          :from="series.data.value?.start"
          :to="series.data.value?.end"
        />
        <div class="foot mono">
          <span>{{ lane.sub }}</span>
          <span>peak {{ lane.format(peak(points(lane.key))) }}</span>
        </div>
      </PanelBox>
    </section>

    <!-- The shared timeline -->
    <section class="timeline">
      <header class="tl-head">
        <span class="label">Timeline</span>
        <div class="tl-axis mono">
          <span v-for="(t, i) in axis" :key="i">{{ t }}</span>
        </div>
        <span class="label right">Current</span>
      </header>

      <!-- Dimmed on the same signal as the headline charts above, which draw
           the SAME series. Leaving the lanes bright while the charts fade
           would say the timeline is current when it is the identical frozen
           data. The Alerts lane below is NOT dimmed: it comes from
           Alertmanager, which is a different source with a different pulse. -->
      <div v-for="lane in LANES" :key="lane.key" class="lane" :class="{ dim: !!metricsStale }">
        <div class="lane-name">
          <div class="lane-label">{{ lane.label }}</div>
          <div class="lane-sub mono">{{ lane.sub }}</div>
        </div>
        <MetricChart
          :points="points(lane.key)"
          :tone="lane.tone"
          :height="30"
          show-median
          :from="series.data.value?.start"
          :to="series.data.value?.end"
        />
        <div class="lane-value">
          <span class="mono now" :style="{ color: `var(--${lane.tone})` }">
            {{ lane.format(latest(points(lane.key))) }}
          </span>
          <div class="lane-peak mono">peak {{ lane.format(peak(points(lane.key))) }}</div>
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
    </section>

    <!-- Bottom row -->
    <section class="bottom">
      <div class="column">
        <PanelBox label="Findings" :stale="batteryStale">
        <template #aside>
          <span v-if="host.doc">{{ host.doc.summary.total }} checks, {{ host.problems.length }} not passing</span>
        </template>

        <ul v-if="host.problems.length" class="findings">
          <li v-for="c in host.problems" :key="c.id" class="finding-row">
            <StatusDot :tone="c.status === 'fail' ? 'fail' : c.status === 'warn' ? 'warn' : 'off'" :size="5" />
            <span class="mono fid">{{ c.id }}</span>
            <span class="fmsg truncate" :title="c.message">{{ c.message }}</span>
          </li>
        </ul>
        <p v-else class="empty mono">every check passed</p>

          <p v-if="host.doc && !host.doc.mode.routes" class="note mono">
            The public route battery was not walked in this run. Those checks are absent, not passing.
          </p>
        </PanelBox>

        <PanelBox label="GPU and playback" :stale="metricsStale">
          <div class="gpu mono">
            <div class="gpu-row">
              <span>encoder</span>
              <span class="gv">{{ fmt.percent(latest(points("gpu")), 0) }}</span>
            </div>
            <div class="gpu-row">
              <span>NVENC sessions</span>
              <span class="gv">{{ fmt.number(gpu.data.value?.sessions ?? Number.NaN) }} of 8</span>
            </div>
            <div class="gpu-row">
              <span>temperature</span>
              <span class="gv">{{ fmt.celsius(gpu.data.value?.temp ?? Number.NaN) }}</span>
            </div>
            <div class="gpu-row">
              <span>board power</span>
              <span class="gv">{{ fmt.watts(gpu.data.value?.power ?? Number.NaN) }}</span>
            </div>
            <div class="gpu-row">
              <span>Jellyfin sessions</span>
              <span class="gv">{{ fmt.number(jellyfinSessions.data.value ?? Number.NaN) }}</span>
            </div>
          </div>
          <p class="note mono">
            Two NVENC sessions already pin the encoder block at 100% while the SM sits near 10%, so a
            third GPU worker cannot encode faster.
          </p>
        </PanelBox>
      </div>

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
    </section>
  </div>
</template>

<style scoped>
.page {
  padding: 16px var(--pad-page) var(--pad-page);
  display: flex;
  flex-direction: column;
  gap: 10px;
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

.picker {
  display: flex;
  gap: 2px;
  padding: 2px;
  border-radius: var(--r-sm);
  background: var(--field);
  border: 1px solid var(--line);
}

.pick {
  padding: 5px 11px;
  border-radius: var(--r-xs);
  font: var(--t-mono-md);
  color: var(--fg-5);
}

.pick:hover {
  color: var(--fg);
}

.pick.on {
  background: oklch(1 0 0 / 0.09);
  color: var(--fg);
}

/* --- actionable strip --- */
.strip {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 9px;
}

.finding {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 10px 13px;
  border-radius: var(--r-sm);
  border: 1px solid var(--warn-edge);
  background: var(--warn-tint);
  min-width: 0;
}

.finding.fail {
  border-color: var(--fail-edge);
  background: var(--fail-tint);
}

.finding-body {
  min-width: 0;
}

.finding-title {
  font: var(--t-ui-md);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.finding-id {
  font: var(--t-mono-sm);
  color: var(--fg-5);
  margin-top: 2px;
}

/* --- headline charts --- */
.headlines {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 9px;
}

.value {
  font: var(--t-mono-lg);
  color: var(--fg);
}

.foot {
  display: flex;
  justify-content: space-between;
  margin-top: 8px;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

/* --- timeline --- */
.timeline {
  margin-top: 6px;
}

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

.sweep {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 60px;
  background: linear-gradient(90deg, transparent, var(--ok-tint), transparent);
  animation: sweep 6s linear infinite;
  pointer-events: none;
}

/* --- bottom --- */
.bottom {
  display: grid;
  grid-template-columns: 1fr 1fr 340px;
  gap: 10px;
  margin-top: 10px;
  align-items: start;
}

.column,
.right-column {
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
}

.findings {
  display: flex;
  flex-direction: column;
  gap: 1px;
  max-height: 320px;
  overflow-y: auto;
}

.finding-row {
  display: grid;
  grid-template-columns: 12px 190px 1fr;
  gap: 9px;
  align-items: center;
  padding: 5px 4px;
  border-radius: var(--r-xs);
}

.finding-row:hover {
  background: oklch(1 0 0 / 0.04);
}

.fid {
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.fmsg {
  font: var(--t-mono-sm);
  color: var(--fg-3);
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

/* --- drives --- */
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
}

.fs-foot {
  color: var(--fg-5);
}

/* --- uptime --- */
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

/* --- gpu --- */
.gpu {
  display: flex;
  flex-direction: column;
  gap: 7px;
}

.gpu-row {
  display: flex;
  justify-content: space-between;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.gv {
  color: var(--fg-2);
  font-weight: 500;
}

@media (max-width: 1280px) {
  .bottom {
    grid-template-columns: 1fr 1fr;
  }

  .headlines {
    grid-template-columns: 1fr;
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
