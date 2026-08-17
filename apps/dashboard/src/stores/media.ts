// =============================================================================
// The two media documents, their freshness, and the merged row set
// -----------------------------------------------------------------------------
// A STORE RATHER THAN usePoll IN EACH PAGE, and the reason is the freshness rule
// rather than tidiness. Both Home and Library read both documents, and usePoll
// stops and restarts on unmount - so per-page polling would reset `lastOk` on
// every Home <-> Library navigation, which is exactly the clock this store's
// staleness is measured against. App.vue's own comment sets the precedent for
// useHostStore: "so the polls are shared and a route change does not restart
// them". The cost is two static-file fetches while sitting on System, and
// usePoll stops entirely when the tab is hidden.
//
// Ages are measured against useHostStore().now, which is Prometheus' clock with
// local drift applied - so there is one 1-second interval in the whole
// application, and a browser with a skewed clock cannot report a fresh document
// as stale.
// =============================================================================

import { computed } from "vue";
import { defineStore } from "pinia";

import { usePoll } from "@/composables/usePoll";
import { DocumentNeverWritten, fetchActivity, fetchLibrary } from "@/api/media";
import { SignedOutError } from "@/api/http";
import { freshness, type Freshness } from "@/freshness";
import { sortRows } from "@/media";
import { coarse, isoToUnix } from "@/format";
import { useHostStore } from "@/stores/host";
import type { ActivityDocument, FileState, LibraryDocument, Transfer } from "@/types";

const ACTIVITY_POLL_MS = 30_000;
const LIBRARY_POLL_MS = 300_000;

// TWO THRESHOLDS FROM ONE PRINCIPLE - four missed writes - rather than two
// guesses. 120s is also the point at which an extrapolated progress bar has
// drifted two whole minutes, which is visible against an HH:MM:SS readout.
const ACTIVITY_STALE_S = 120;
const LIBRARY_STALE_S = 1200;

/**
 * How far past a document's own timestamp a playback position may be
 * extrapolated. Playback advances at exactly 1x, so predicting it is more
 * accurate than showing a figure up to thirty seconds old - but only while the
 * session is still playing, and "still playing" is precisely the assumption that
 * stops holding the moment the collector stops. Past this, the bar greys.
 */
export const EXTRAPOLATE_MAX_S = 30;

/** How many rows the table will render before it says it stopped. A cap that is
 *  visible is honest; a virtualiser that hides one is not. */
export const RENDER_CAP = 200;

export const useMediaStore = defineStore("media", () => {
  const host = useHostStore();

  const activity = usePoll<ActivityDocument>((signal) => fetchActivity(signal), ACTIVITY_POLL_MS);
  const library = usePoll<LibraryDocument>((signal) => fetchLibrary(signal), LIBRARY_POLL_MS);

  const activityDoc = computed(() => activity.data.value);
  const libraryDoc = computed(() => library.data.value);

  const signedOut = computed(
    () => activity.error.value instanceof SignedOutError || library.error.value instanceof SignedOutError,
  );

  const activityNeverRun = computed(() => activity.error.value instanceof DocumentNeverWritten);
  const libraryNeverRun = computed(() => library.error.value instanceof DocumentNeverWritten);

  /** Read from the document's own generated_at, NOT from a Prometheus mirror of
   *  it, so a dead collector and a dead scrape stay distinguishable. */
  const activityFreshness = computed<Freshness>(() =>
    freshness("playback", isoToUnix(activityDoc.value?.generated_at), host.now, ACTIVITY_STALE_S),
  );

  const libraryFreshness = computed<Freshness>(() =>
    freshness("library", isoToUnix(libraryDoc.value?.generated_at), host.now, LIBRARY_STALE_S),
  );

  const activityStale = computed(() => {
    if (activityNeverRun.value) return "playback has not been reported on this host";
    const f = activityFreshness.value;
    if (f.missing) return "activity.json could not be read";
    if (f.stale) return `playback last reported ${coarse(f.age)} ago; anything below is from then`;
    return null;
  });

  const libraryStale = computed(() => {
    if (libraryNeverRun.value) return "the library document has not been written on this host";
    const f = libraryFreshness.value;
    if (f.missing) return "library.json could not be read";
    if (f.stale) return `the library was last read ${coarse(f.age)} ago`;
    return null;
  });

  /**
   * "jellyseerr did not answer in this run; requests are absent, not zero."
   *
   * This is what `sources` is for. Without it an upstream timing out and an
   * upstream with nothing to report are the same empty list, and a page
   * rendering that as "nothing to approve" would be confidently wrong.
   */
  const sourceNotes = computed(() => {
    const notes: string[] = [];
    for (const doc of [activityDoc.value, libraryDoc.value]) {
      for (const [name, health] of Object.entries(doc?.sources ?? {})) {
        if (!health.ok) notes.push(`${name} did not answer in this run; its rows are absent, not zero`);
      }
    }
    return notes;
  });

  const sessions = computed(() => activityDoc.value?.sessions ?? []);
  const requests = computed(() => libraryDoc.value?.requests ?? []);
  const recent = computed(() => libraryDoc.value?.recently_added ?? []);
  const recentTotal = computed(() => libraryDoc.value?.recently_added_total ?? 0);
  const totals = computed(() => libraryDoc.value?.totals ?? null);

  /**
   * Every row the Library table can show, from three lists in two documents.
   *
   * DEDUPED BY id WITH THE FAST DOCUMENT WINNING. An item that finishes between
   * the two writes legitimately appears in both, and the fast one is the more
   * recent account of it. `origin` is kept so the table can dim the live rows
   * without dimming completions that came from a document which is still fresh.
   */
  const rows = computed<MediaRow[]>(() => {
    const out = new Map<string, MediaRow>();
    for (const row of libraryDoc.value?.done ?? []) {
      out.set(row.id, { ...row, origin: "library", searchKey: searchKeyOf(row) });
    }
    for (const row of libraryDoc.value?.attention ?? []) {
      out.set(row.id, { ...row, origin: "library", searchKey: searchKeyOf(row) });
    }
    for (const row of activityDoc.value?.transfers ?? []) {
      out.set(row.id, { ...row, origin: "activity", searchKey: searchKeyOf(row) });
    }
    return [...out.values()].sort(sortRows);
  });

  /** Counts over the WHOLE row set, never over the filtered view - that is the
   *  entire point of a count on a filter control. */
  const counts = computed(() => {
    const by = {} as Record<FileState, number>;
    for (const row of rows.value) by[row.state] = (by[row.state] ?? 0) + 1;
    return by;
  });

  const pending = computed(() => activity.pending.value || library.pending.value);

  function refresh() {
    return Promise.all([activity.refresh(), library.refresh()]);
  }

  return {
    activityDoc,
    libraryDoc,
    activityFreshness,
    libraryFreshness,
    activityStale,
    libraryStale,
    activityNeverRun,
    libraryNeverRun,
    signedOut,
    sourceNotes,
    sessions,
    requests,
    recent,
    recentTotal,
    totals,
    rows,
    counts,
    pending,
    refresh,
  };
});

export interface MediaRow extends Transfer {
  /** Which document this came from, so the two can dim independently. */
  origin: "activity" | "library";
  /** Lowercased title and path, precomputed per document change rather than per
   *  keystroke. */
  searchKey: string;
}

function searchKeyOf(row: Transfer): string {
  return `${row.title} ${row.sub ?? ""} ${row.path ?? ""}`.toLowerCase();
}
