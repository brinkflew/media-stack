<script setup lang="ts">
/**
 * Home: what is happening in the house right now.
 *
 * Three rows, everything above the fold at 1360x860, and no system resources -
 * those have a page of their own. The design calls this "media and activity
 * only", and the discipline is that a number belongs here only if somebody who
 * is not administering the server would care about it.
 *
 * THE SHELL SEARCH FIELD IS DROPPED. The design puts "search or request" in the
 * nav; half of that is a write, which is structurally impossible here, and the
 * other half has nothing to search - the documents carry the working set and the
 * last seven days, not an index of 617 items. A field that silently only searched
 * the last week would be worse than no field.
 */
import { computed } from "vue";

import PanelBox from "@/components/PanelBox.vue";
import PosterTile from "@/components/PosterTile.vue";
import NowPlayingCard from "@/components/NowPlayingCard.vue";
import ServiceStrip from "@/components/ServiceStrip.vue";
import StaleNote from "@/components/StaleNote.vue";
import ChipLink from "@/components/ChipLink.vue";

import { useHostStore } from "@/stores/host";
import { useMediaStore } from "@/stores/media";
import { jellyfinItem, jellyseerrRequests } from "@/links";
import * as fmt from "@/format";

const media = useMediaStore();
const host = useHostStore();

/** Up to three cards, which is what this host actually runs to. The design draws
 *  two; --cards is SystemPage's existing idiom for a per-item grid, reused rather
 *  than reinvented, and it makes zero sessions and three the same mechanism. */
const MAX_CARDS = 3;

const cards = computed(() => media.sessions.slice(0, MAX_CARDS));
const overflow = computed(() => Math.max(0, media.sessions.length - MAX_CARDS));

const pending = computed(() => media.libraryDoc?.request_counts?.pending ?? null);
const requestTotal = computed(() => media.libraryDoc?.request_counts?.total ?? 0);

/** The newest eight. Two rows of posters would push the service strip below the
 *  fold at 860, and this row is a glance rather than an inventory - the header
 *  carries the true total. */
const grid = computed(() => media.recent.slice(0, 8));

function requestMeta(r: (typeof media.requests)[number]): string {
  const kind = r.kind === "series" ? "series" : "movie";
  // coarse, not sinceIso: the design's line is "series, asked 2h ago", and
  // sinceIso spells the same thing as "2h 03m ago" - which reads as false
  // precision for something somebody asked for yesterday, and already carries
  // its own "ago".
  const at = fmt.isoToUnix(r.requested_at);
  if (!Number.isFinite(at)) return kind;
  // host.now, not Date.now(), so every age on the page runs off the same
  // Prometheus-corrected clock.
  return `${kind}, asked ${fmt.coarse(host.now - at)} ago`;
}
</script>

<template>
  <div class="page">
    <Teleport defer to="#toolbar">
      <!-- The page's freshness affordance, in the one place every page puts its
           controls. Two documents, two ages, because they go stale at different
           rates and a single number would hide which one did. -->
      <span class="mono ages">
        playback
        <span :class="{ bad: !!media.activityStale }">
          {{ fmt.coarse(media.activityFreshness.age) }}
        </span>
        / library
        <span :class="{ bad: !!media.libraryStale }">
          {{ fmt.coarse(media.libraryFreshness.age) }}
        </span>
      </span>
    </Teleport>

    <!-- Row 1: now playing, and the queue somebody else is waiting on -->
    <section class="row-one" :style="{ '--cards': Math.max(1, cards.length) }">
      <PanelBox v-for="s in cards" :key="s.id" :stale="media.activityStale">
        <NowPlayingCard :session="s" :doc-at="media.activityDoc?.generated_at ?? ''" />
      </PanelBox>

      <!-- FRESH-AND-EMPTY AND STALE-AND-EMPTY ARE DIFFERENT CLAIMS, the same way
           they are in the Library table. "Nothing playing" is an assertion, and at
           eight minutes old it is one we are not entitled to make - so it becomes
           "no session as of Nm ago" instead. The age line is what turns an absence
           into a statement rather than a shrug. -->
      <PanelBox v-if="!cards.length" :stale="media.activityStale">
        <p v-if="media.activityStale" class="empty mono">
          no session as of {{ fmt.coarse(media.activityFreshness.age) }} ago
          <span class="asked">which is not the same as nobody watching</span>
        </p>
        <p v-else class="empty mono">
          nothing playing
          <span class="asked">asked {{ fmt.coarse(media.activityFreshness.age) }} ago</span>
        </p>
      </PanelBox>

      <!-- A CAP THAT IS VISIBLE IS HONEST. Three cards is a layout limit, not a
           statement about how many people are watching, so the difference is
           said out loud rather than quietly dropped. -->
      <p v-if="overflow" class="overflow mono">
        + {{ overflow }} more session{{ overflow === 1 ? "" : "s" }} not shown
      </p>

      <PanelBox label="Requests" :stale="media.libraryStale">
        <template #aside>
          <span v-if="pending" class="mono pending">{{ pending }} pending</span>
        </template>

        <ul v-if="media.requests.length" class="requests">
          <li v-for="r in media.requests.slice(0, 4)" :key="r.id" class="request">
            <PosterTile :path="r.poster" :tag="r.poster_tag" :width="26" :height="38" :title="r.title" :kind="r.kind" />
            <span class="rtext">
              <span class="rtitle truncate" :title="r.title">{{ r.title }}</span>
              <span class="rmeta mono">{{ requestMeta(r) }}</span>
            </span>
            <ChipLink
              label="open"
              :href="jellyseerrRequests()"
              title="open the request queue in Jellyseerr"
              tone="ok"
            />
          </li>
        </ul>

        <!-- The count in the header is authoritative over ALL requests; the list
             is the newest handful. So an empty list with a non-zero count is
             possible rather than contradictory, and saying "no requests" there
             would flatly disagree with the number beside it. -->
        <p v-else class="empty mono">
          {{ requestTotal ? `none of the newest ${requestTotal} shown` : "no requests" }}
          <span class="asked">asked {{ fmt.coarse(media.libraryFreshness.age) }} ago</span>
        </p>
      </PanelBox>
    </section>

    <!-- Row 2: recently added -->
    <section class="added-head">
      <span class="label">Recently added</span>
      <span class="mono counts">{{ media.recentTotal }} items in the last 7 days</span>
    </section>

    <StaleNote :reason="media.libraryStale" />

    <div v-if="grid.length" class="grid" :class="{ dim: !!media.libraryStale }">
      <a
        v-for="item in grid"
        :key="item.id"
        class="cell"
        :href="item.item_id ? jellyfinItem(item.item_id) ?? undefined : undefined"
        target="_blank"
        rel="noopener noreferrer"
      >
        <PosterTile
          :path="item.poster"
          :tag="item.poster_tag"
          :width="150"
          :title="item.title"
          :kind="item.kind"
        />
        <span class="ctitle truncate" :title="item.title">{{ item.title }}</span>
        <span class="cmeta mono">{{ item.sub ?? "" }}</span>
      </a>
    </div>

    <p v-else class="empty mono">
      nothing added in the last 7 days
      <span class="asked">asked {{ fmt.coarse(media.libraryFreshness.age) }} ago</span>
    </p>

    <!-- Any upstream that did not answer says so, rather than reading as zero -->
    <p v-for="note in media.sourceNotes" :key="note" class="source-note mono">{{ note }}</p>

    <!-- Row 3: the service strip -->
    <ServiceStrip />

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

.ages {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.ages .bad {
  color: var(--warn);
}

.row-one {
  display: grid;
  grid-template-columns: repeat(var(--cards, 2), minmax(0, 1fr)) 300px;
  gap: 10px;
  align-items: stretch;
}

.pending {
  font: var(--t-mono-xs);
  color: var(--warn);
}

.overflow {
  align-self: end;
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.requests {
  display: flex;
  flex-direction: column;
  gap: 9px;
}

.request {
  display: grid;
  grid-template-columns: 26px minmax(0, 1fr) auto;
  align-items: center;
  gap: 9px;
}

.rtext {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.rtitle {
  font: var(--t-ui-sm);
  color: var(--fg-2);
}

.rmeta {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

/* --- recently added --- */
.added-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-top: 4px;
}

.counts {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.grid {
  display: grid;
  grid-template-columns: repeat(8, minmax(0, 1fr));
  gap: 9px;
}

.dim {
  opacity: 0.4;
  filter: saturate(0.5);
}

.cell {
  display: flex;
  flex-direction: column;
  gap: 5px;
  min-width: 0;
}

/* PosterTile is sized in px, so it is stretched to the column here rather than
   the grid being sized to it - eight fixed-width posters would not fit 1360. */
.cell :deep(.tile) {
  width: 100% !important;
  height: auto !important;
  aspect-ratio: 2 / 3;
  transition: border-color 0.12s ease-out;
}

.cell:hover :deep(.tile) {
  border-color: var(--ok-edge);
}

.ctitle {
  font: var(--t-ui-sm);
  font-size: 11px;
  font-weight: 500;
  color: var(--fg-2);
}

.cmeta {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

/* --- shared --- */
.empty {
  display: flex;
  flex-direction: column;
  gap: 3px;
  font: var(--t-mono-sm);
  color: var(--fg-dim);
}

.asked {
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.source-note {
  font: var(--t-mono-sm);
  color: var(--warn);
}

.footnote {
  margin-top: 2px;
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}
</style>
