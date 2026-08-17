<script setup lang="ts">
/**
 * Library: every file and the state it is in.
 *
 * THE MOST IMPORTANT THING ON THIS PAGE IS ITS EMPTY STATE, and that is not a
 * remark about polish. An almost-empty table is the NORMAL, HEALTHY rendering
 * here: `library/queued/` holding no video files means bin/promote-transcoded.py
 * is doing its job, and Tdarr's file table draining to zero is documented design
 * rather than a fault. Measured on the live host the day this was written: 1
 * download, 0 transcoding, 0 queued, 145 completions in a week.
 *
 * So there are three empty states and they say three different things. "Nothing
 * is in flight", "you filtered everything out" and "nobody has asked in eight
 * minutes" are different facts, and collapsing them is the same failure as
 * rendering `mode.routes: false` as "every route passed".
 *
 * SORTED ATTENTION-FIRST, WHICH THE DESIGN'S FOOTER DID NOT SAY. See sortRows in
 * @/media for the argument; the footer text here is corrected to match rather
 * than the sort being bent to it.
 */
import { computed, ref } from "vue";

import PosterTile from "@/components/PosterTile.vue";
import StatePill from "@/components/StatePill.vue";
import ProgressBar from "@/components/ProgressBar.vue";
import ChipLink from "@/components/ChipLink.vue";
import StaleNote from "@/components/StaleNote.vue";

import { usePoll } from "@/composables/usePoll";
import { useMetricsStale } from "@/composables/useStaleness";
import { instantBy } from "@/api/prometheus";
import { SYSTEM } from "@/queries";
import { RENDER_CAP, useMediaStore, type MediaRow } from "@/stores/media";
import { STATE_LABEL, STATE_TONE, actionFor, stateClass } from "@/media";
import { bazarr, tdarr } from "@/links";
import type { FileState } from "@/types";
import * as fmt from "@/format";

const media = useMediaStore();
const metricsStale = useMetricsStale();

// --- filters ----------------------------------------------------------------
type View = "all" | "active" | "attention" | "series" | "movie";

const ACTIVE_STATES: FileState[] = ["downloading", "transcoding", "importing"];
const ATTENTION_STATES: FileState[] = ["stalled", "error", "no_subtitles"];

/** Shown in the filtered-empty sentence when no text filter is set. */
const VIEW_HINT = "this view";

const view = ref<View>("all");
const filter = ref("");

function inView(row: MediaRow, v: View): boolean {
  if (v === "active") return ACTIVE_STATES.includes(row.state);
  if (v === "attention") return ATTENTION_STATES.includes(row.state);
  if (v === "series" || v === "movie") return row.kind === v;
  return true;
}

/**
 * Counts are computed over the WHOLE row set and never over the current view -
 * that is the entire point of a count on a filter control. A zero chip stays
 * clickable too: clicking "needs attention 0" should show the filtered-empty
 * state, and a disabled chip is indistinguishable from a broken one.
 */
const chips = computed(() => {
  const rows = media.rows;
  const count = (v: View) => rows.filter((r) => inView(r, v)).length;
  return [
    { id: "all" as View, label: "all", n: rows.length, tone: "off" as const },
    { id: "active" as View, label: "active", n: count("active"), tone: "ok" as const },
    { id: "attention" as View, label: "needs attention", n: count("attention"), tone: "warn" as const },
    { id: "series" as View, label: "tv", n: count("series"), tone: "off" as const },
    { id: "movie" as View, label: "movies", n: count("movie"), tone: "off" as const },
  ];
});

const visible = computed(() => {
  const needle = filter.value.trim().toLowerCase();
  // No debounce. 150 string comparisons per keystroke is free, and a debounce on
  // a local filter only adds lag - it is exactly what somebody will add later.
  return media.rows.filter((r) => inView(r, view.value) && (!needle || r.searchKey.includes(needle)));
});

const shown = computed(() => visible.value.slice(0, RENDER_CAP));

// --- stat blocks -------------------------------------------------------------
const stats = computed(() => {
  const c = media.counts;
  return [
    { label: "downloading", n: c.downloading ?? 0, tone: "ok" as const, href: null as string | null, title: "" },
    { label: "transcoding", n: c.transcoding ?? 0, tone: "ok" as const, href: tdarr(), title: "open Tdarr" },
    { label: "queued", n: c.queued ?? 0, tone: "off" as const, href: null, title: "" },
    {
      label: "needs attention",
      n: (c.stalled ?? 0) + (c.error ?? 0) + (c.no_subtitles ?? 0),
      tone: "warn" as const,
      href: null,
      title: "",
    },
    { label: "done, 7 days", n: media.recentTotal, tone: "off" as const, href: null, title: "" },
    {
      // THE SIXTH BLOCK, WHICH THE DESIGN DOES NOT HAVE. It is the largest real
      // number on this page and the only backlog this host actually has, so
      // omitting it would be hiding it. It stays a COUNT and never becomes rows:
      // 543 of them would swamp a ~150-row table and make the page useless.
      label: "subtitles",
      n: media.totals?.no_subtitle_episodes ?? 0,
      tone: "warn" as const,
      href: bazarr(),
      title: "episodes with at least one missing subtitle - Bazarr's backlog, not a queue",
    },
  ];
});

// --- the footer's right half ------------------------------------------------
const disk = usePoll(async (signal) => {
  const [size, avail] = await Promise.all([
    instantBy(SYSTEM.filesystems, "mountpoint", signal),
    instantBy(SYSTEM.filesystemAvail, "mountpoint", signal),
  ]);
  // The metric's own mountpoint label, not the design's /mnt/media: a path is a
  // mono fact and has to be the real one. On CoreOS /mnt is a symlink into /var,
  // which is why the canonical path is what the collector reports.
  const mount = "/var/mnt/media";
  const total = size.get(mount) ?? Number.NaN;
  const free = avail.get(mount) ?? Number.NaN;
  return { mount, total, used: total - free };
}, 60_000);

/** Which empty state applies, if any. Three strings, not one. */
const emptiness = computed<"none" | "filtered" | "stale" | "fresh">(() => {
  if (visible.value.length) return "none";
  if (media.rows.length) return "filtered";
  // Stale-and-empty must NEVER read as "nothing in flight": at eight minutes old
  // that is an assertion we are not entitled to make. This is the sharpest
  // expression of the freshness rule on either page.
  if (media.activityStale) return "stale";
  return "fresh";
});
</script>

<template>
  <div class="page">
    <Teleport defer to="#toolbar">
      <input v-model="filter" class="mono search" type="search" placeholder="filter by title or path" />
      <ChipLink label="scan" :href="tdarr()" title="open Tdarr, which owns the transcode queue" />
    </Teleport>

    <!-- Filter row: views on the left, the numbers on the right -->
    <section class="controls">
      <div class="chips">
        <button
          v-for="c in chips"
          :key="c.id"
          class="chip mono"
          :class="{ on: view === c.id, warn: c.tone === 'warn' && c.n > 0 }"
          @click="view = c.id"
        >
          {{ c.label }} <span class="n">{{ c.n }}</span>
        </button>
      </div>

      <div class="stats">
        <component
          :is="s.href ? 'a' : 'div'"
          v-for="s in stats"
          :key="s.label"
          class="stat"
          :href="s.href ?? undefined"
          :title="s.title"
          :target="s.href ? '_blank' : undefined"
          :rel="s.href ? 'noopener noreferrer' : undefined"
        >
          <span class="mono sn" :class="s.n > 0 ? s.tone : 'off'">{{ s.n }}</span>
          <span class="sl">{{ s.label }}</span>
        </component>
      </div>
    </section>

    <StaleNote :reason="media.activityStale" />
    <p v-for="note in media.sourceNotes" :key="note" class="source-note mono">{{ note }}</p>

    <!-- The table. --cols is defined ONCE so the header and the rows cannot
         drift apart, which is the one improvement on ServicesPage's rack. -->
    <div class="table" :class="{ dim: !!media.activityStale }">
      <div class="row head mono">
        <span>TITLE</span>
        <span>STATE</span>
        <span>PROGRESS</span>
        <span>DETAIL</span>
        <span class="r">SIZE</span>
        <span class="r">RATE</span>
        <span class="r">ACTION</span>
      </div>

      <div class="body">
        <div v-for="row in shown" :key="row.id" class="row">
          <div class="title-cell">
            <PosterTile
              :path="row.poster"
              :tag="row.poster_tag"
              :width="22"
              :height="32"
              :title="row.title"
              :kind="row.kind"
            />
            <span class="tstack">
              <span class="ttitle truncate" :title="row.title">{{ row.title }}</span>
              <span class="tsub mono">{{ row.sub ?? "" }}</span>
            </span>
          </div>

          <div><StatePill :label="STATE_LABEL[row.state]" :tone="STATE_TONE[row.state]" /></div>

          <div class="progress-cell">
            <ProgressBar
              :ratio="row.progress"
              :tone="STATE_TONE[row.state]"
              :live="stateClass(row.state) === 'live'"
            />
            <span class="mono pct">
              {{ row.progress === null ? fmt.NO_DATA : fmt.percent(row.progress, 0) }}
            </span>
          </div>

          <div class="detail">
            <!-- Rendered even when empty, with a min-height, so every row keeps
                 one baseline - the same trick SystemPage's axis ticks use. -->
            <span class="note truncate" :title="row.note ?? ''">{{ row.note ?? "" }}</span>
            <span class="src mono truncate">
              {{ [row.source, row.quality].filter(Boolean).join(" / ") }}
            </span>
          </div>

          <div class="r mono cell">{{ row.size === null ? fmt.NO_DATA : fmt.bytes(row.size) }}</div>

          <div class="r mono cell rate">
            <!-- A rate of 0 is a fact for a seeding torrent with no peers, so the
                 note is the fallback only when there is genuinely no rate. -->
            <span v-if="row.rate_bps !== null && row.rate_bps > 0">{{ fmt.rate(row.rate_bps) }}</span>
            <span v-else-if="row.rate_note">{{ row.rate_note }}</span>
            <span v-else>{{ fmt.NO_DATA }}</span>
          </div>

          <div class="r">
            <ChipLink
              :label="actionFor(row).label"
              :href="actionFor(row).href"
              :title="actionFor(row).title"
            />
          </div>
        </div>

        <!-- THREE EMPTY STATES, THREE SENTENCES -->
        <p v-if="emptiness === 'fresh'" class="empty mono">
          nothing in flight. the queue drains to zero by design.
          <span class="asked">asked {{ fmt.coarse(media.activityFreshness.age) }} ago</span>
        </p>

        <p v-else-if="emptiness === 'stale'" class="empty mono">
          no rows as of {{ fmt.coarse(media.activityFreshness.age) }} ago
          <span class="asked">which is not the same as nothing being in flight</span>
        </p>

        <p v-else-if="emptiness === 'filtered'" class="empty mono">
          no row matches <span class="needle">{{ filter || VIEW_HINT }}</span>
          <button class="clear mono" @click="filter = ''; view = 'all'">clear filter</button>
        </p>
      </div>
    </div>

    <footer class="foot">
      <span class="mono" :class="{ dim: !!media.activityStale }">
        showing {{ shown.length }} of {{ media.rows.length }}, sorted by attention then activity
        <span v-if="visible.length > shown.length">({{ visible.length - shown.length }} beyond the render cap)</span>
      </span>
      <span class="mono" :class="{ dim: !!metricsStale }">
        {{ disk.data.value?.mount ?? "/var/mnt/media" }},
        {{ fmt.bytes(disk.data.value?.used ?? Number.NaN) }} of
        {{ fmt.bytes(disk.data.value?.total ?? Number.NaN) }} used
      </span>
    </footer>

    <p class="footnote mono">
      every action here opens the owning application in a new tab; this dashboard writes nothing
    </p>
  </div>
</template>

<style scoped>
.page {
  padding: 16px var(--pad-page) var(--pad-page);
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.search {
  width: 210px;
  padding: 4px 8px;
  font: var(--t-mono-sm);
  color: var(--fg);
  background: var(--field);
  border: 1px solid var(--line);
  border-radius: var(--r-sm);
}

.search::placeholder {
  color: var(--fg-dim);
}

/* --- controls --- */
.controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}

.chips {
  display: flex;
  gap: 2px;
  padding: 2px;
  background: var(--field);
  border: 1px solid var(--line);
  border-radius: var(--r-sm);
}

.chip {
  padding: 4px 10px;
  font: var(--t-mono-xs);
  color: var(--fg-5);
  border-radius: var(--r-xs);
}

.chip:hover {
  color: var(--fg-2);
}

.chip.on {
  background: oklch(1 0 0 / 0.09);
  color: var(--fg);
}

.chip .n {
  color: var(--fg-dim);
}

.chip.warn .n {
  color: var(--warn);
}

.stats {
  display: flex;
  gap: 18px;
}

.stat {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 1px;
}

a.stat:hover .sl {
  color: var(--fg-2);
}

.sn {
  font: var(--t-mono-lg);
}

.sn.ok {
  color: var(--ok);
}

.sn.warn {
  color: var(--warn);
}

.sn.off {
  color: var(--fg-4);
}

.sl {
  font: var(--t-label);
  text-transform: uppercase;
  letter-spacing: var(--track-label);
  color: var(--fg-5);
}

/* --- the table --- */
.table {
  --cols: 1.5fr 118px 138px 1fr 92px 116px 104px;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: var(--r-md);
}

.dim {
  opacity: 0.4;
  filter: saturate(0.5);
}

.row {
  display: grid;
  grid-template-columns: var(--cols);
  gap: 12px;
  align-items: center;
  padding: 7px 13px;
  border-bottom: 1px solid var(--line-faint);
}

.head {
  position: sticky;
  top: 0;
  z-index: 1;
  font: var(--t-label);
  text-transform: uppercase;
  letter-spacing: var(--track-label);
  color: var(--fg-5);
  background: var(--surface-raised);
  border-radius: var(--r-md) var(--r-md) 0 0;
}

.body {
  max-height: 520px;
  overflow-y: auto;
}

.body .row:last-child {
  border-bottom: none;
}

.r {
  text-align: right;
  justify-self: end;
}

.cell {
  font: var(--t-mono-sm);
  color: var(--fg-2);
}

.title-cell {
  display: grid;
  grid-template-columns: 22px minmax(0, 1fr);
  align-items: center;
  gap: 9px;
}

.tstack {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.ttitle {
  font: var(--t-ui-sm);
  color: var(--fg);
}

.tsub {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.progress-cell {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.pct {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.detail {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.note {
  min-height: 14px;
  font: var(--t-ui-sm);
  font-size: 11px;
  color: var(--fg-4);
}

.src {
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.rate span {
  color: var(--fg-2);
}

/* --- empty and foot --- */
.empty {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 5px;
  padding: 28px 13px;
  font: var(--t-mono-sm);
  color: var(--fg-dim);
}

.asked {
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.needle {
  color: var(--fg-4);
}

.clear {
  padding: 3px 8px;
  font: var(--t-mono-xs);
  color: var(--fg-4);
  background: var(--surface-chip);
  border: 1px solid var(--line);
  border-radius: var(--r-xs);
}

.clear:hover {
  color: var(--fg);
  border-color: var(--line-strong);
}

.foot {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 16px;
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.source-note {
  font: var(--t-mono-sm);
  color: var(--warn);
}

.footnote {
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}
</style>
