// =============================================================================
// The two staleness reasons every page hands to its panels
// -----------------------------------------------------------------------------
// These were duplicated VERBATIM in SystemPage.vue and ServicesPage.vue. Home
// and Library need them too, and four copies of a sentence that has to stay
// consistent is how a panel ends up claiming the collector is fine while the
// banner above it says otherwise. The strings are moved unchanged, so the diff
// that introduced this file is provably a move rather than a rewrite.
//
// They are REASONS, not booleans. PanelBox takes `stale` as a string and prints
// it, because "these numbers are frozen" is the useful half - a dimmed panel
// with no explanation is just a broken-looking panel.
//
// The page decides and passes down, rather than each panel asking the store,
// for the reason PanelBox's own comment gives: a panel does not know which of
// its numbers came from where, and a component that dims itself will eventually
// dim for the wrong reason.
// =============================================================================

import { computed, type ComputedRef } from "vue";

import * as fmt from "@/format";
import { useHostStore } from "@/stores/host";

/** Prometheus, and the collector that feeds it. */
export function useMetricsStale(): ComputedRef<string | null> {
  const host = useHostStore();
  return computed(() => {
    if (host.prometheusDown) return "prometheus is unreachable; this is the last answer it gave";
    const f = host.collectorFreshness;
    if (f.missing) return "the collector has never reported";
    if (f.stale) return `the collector last ran ${fmt.duration(f.age)} ago; these numbers are frozen`;
    return null;
  });
}

/** bin/verify-host.sh, whose findings are the prose half of the dashboard. */
export function useBatteryStale(): ComputedRef<string | null> {
  const host = useHostStore();
  return computed(() => {
    if (host.statusNeverRun) return "the check battery has never run on this host";
    const f = host.statusFreshness;
    if (f.missing) return "status.json could not be read";
    if (f.stale) return `the battery last ran ${fmt.duration(f.age)} ago`;
    return null;
  });
}
