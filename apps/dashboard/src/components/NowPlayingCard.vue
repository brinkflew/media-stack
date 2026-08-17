<script setup lang="ts">
/**
 * One session, in five states.
 *
 * THE EXTRAPOLATION IS THE INTERESTING PART, and it is bounded rather than
 * clever. Playback advances at exactly 1x in real time, so position + (now -
 * generated_at) is MORE accurate than a figure up to thirty seconds stale. It is
 * the one number on this dashboard that can honestly be predicted rather than
 * measured, and the brief asks for "motion that carries data" - this is where
 * that is a measurement rather than a decoration.
 *
 * Four guards, because the assumption it rests on is exactly the one that stops
 * holding when the collector dies:
 *
 *   1. only while not paused - a paused stream advances by nothing;
 *   2. capped at EXTRAPOLATE_MAX_S past the document's own timestamp, past which
 *      the bar greys and the dot stops breathing. "Still playing" is precisely
 *      what we can no longer assume once nobody has told us in a while;
 *   3. clamped to the runtime. Overrunning it is itself evidence the session
 *      ended and we were not told, so it freezes at 100% rather than counting on;
 *   4. driven by the store's Prometheus-corrected clock, not Date.now(), so a
 *      skewed browser cannot invent progress.
 */
import { computed } from "vue";

import PosterTile from "@/components/PosterTile.vue";
import StatePill from "@/components/StatePill.vue";
import StatusDot from "@/components/StatusDot.vue";
import ProgressBar from "@/components/ProgressBar.vue";
import ChipLink from "@/components/ChipLink.vue";

import { badgeFor, whoLine } from "@/media";
import { jellyfinItem } from "@/links";
import { EXTRAPOLATE_MAX_S } from "@/stores/media";
import { useHostStore } from "@/stores/host";
import { isoToUnix } from "@/format";
import * as fmt from "@/format";
import type { PlaybackSession } from "@/types";

const props = defineProps<{
  session: PlaybackSession;
  /** The activity document's own generated_at, as an ISO string. */
  docAt: string;
}>();

const host = useHostStore();

/** Seconds since the document was written, floored at 0. */
const age = computed(() => Math.max(0, host.now - isoToUnix(props.docAt)));

/** True once we can no longer honestly claim the session is still running. */
const frozen = computed(() => age.value > EXTRAPOLATE_MAX_S);

const position = computed(() => {
  const base = props.session.position_s;
  if (base === null || !Number.isFinite(base)) return null;
  if (props.session.paused || frozen.value) return base;
  const runtime = props.session.runtime_s;
  const advanced = base + age.value;
  return runtime !== null && Number.isFinite(runtime) ? Math.min(advanced, runtime) : advanced;
});

const ratio = computed(() => {
  const p = position.value;
  const runtime = props.session.runtime_s;
  if (p === null || runtime === null || !Number.isFinite(runtime) || runtime <= 0) return null;
  return p / runtime;
});

const badge = computed(() => badgeFor(props.session));

/** PLAYING / PAUSED, and the dot only breathes for the first. A breathing dot on
 *  a paused stream would be motion carrying no data. */
const live = computed(() => !props.session.paused && !frozen.value);

const label = computed(() => (props.session.paused ? "PAUSED" : "PLAYING"));

const title = computed(() => props.session.series ?? props.session.title);
const subtitle = computed(() =>
  props.session.series ? [props.session.sub, props.session.title].filter(Boolean).join(" - ") : props.session.sub,
);

const action = computed(() => ({
  // "open", not the design's "terminate": the reachable Jellyfin target is the
  // item page, which cannot terminate anything. A chip that lands somewhere it
  // cannot act is the confident-but-wrong affordance this repository refuses.
  href: props.session.item_id ? jellyfinItem(props.session.item_id) : null,
  title: "open this item in Jellyfin",
}));
</script>

<template>
  <div class="card" :class="{ frozen }">
    <PosterTile
      :path="session.poster"
      :tag="session.poster_tag"
      :width="76"
      :height="110"
      :title="title"
      :kind="session.kind"
    />

    <div class="body">
      <div class="top">
        <StatusDot :tone="frozen ? 'off' : 'ok'" :live="live" :size="5" />
        <span class="label">{{ label }}</span>
        <StatePill :label="badge.label" :tone="frozen ? 'off' : badge.tone" size="sm" />
      </div>

      <p class="title truncate" :title="title">{{ title }}</p>
      <p v-if="subtitle" class="sub mono truncate" :title="subtitle">{{ subtitle }}</p>
      <p class="who mono truncate" :title="whoLine(session)">{{ whoLine(session) }}</p>

      <div class="foot">
        <ProgressBar :ratio="ratio" :tone="frozen ? 'off' : 'ok'" :live="live" :height="4" />
        <div class="times">
          <span class="mono time">
            {{ position === null ? fmt.NO_DATA : fmt.elapsed(position) }}
            <span v-if="session.runtime_s" class="of">/ {{ fmt.elapsed(session.runtime_s) }}</span>
          </span>
          <ChipLink label="open" :href="action.href" :title="action.title" tone="ok" />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.card {
  display: flex;
  gap: 11px;
  align-items: stretch;
}

/* Dimmed rather than blanked: the last known content is still the most useful
   thing on screen, and the panel's stale line says how old it is. */
.frozen {
  opacity: 0.55;
  filter: saturate(0.6);
}

.body {
  display: flex;
  flex-direction: column;
  min-width: 0;
  flex: 1;
}

.top {
  display: flex;
  align-items: center;
  gap: 6px;
}

.title {
  margin-top: 7px;
  font: var(--t-ui-md);
  font-weight: 500;
  color: var(--fg);
}

.sub {
  margin-top: 2px;
  font: var(--t-mono-sm);
  color: var(--fg-4);
}

.who {
  margin-top: 3px;
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.foot {
  margin-top: auto;
  padding-top: 9px;
}

.times {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-top: 6px;
}

.time {
  font: var(--t-mono-md);
  color: var(--fg-2);
}

.of {
  color: var(--fg-dim);
}
</style>
