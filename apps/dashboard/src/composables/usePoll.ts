// =============================================================================
// The polling primitive
// -----------------------------------------------------------------------------
// Everything live on this dashboard is a poll, because Prometheus pulls and
// there is nothing to subscribe to. Three behaviours are worth having in one
// place rather than in fifteen:
//
//   1. IT STOPS WHEN THE TAB IS HIDDEN, and refreshes the moment it comes
//      back. A dashboard left open on a second monitor overnight would
//      otherwise issue ~2,900 range queries at 30s against a Prometheus that
//      is also serving the alert evaluator every 30s, for nobody.
//
//   2. THE PREVIOUS ANSWER SURVIVES A FAILED POLL, but `lastOk` does not
//      advance. That is the whole contract: the data keeps rendering, and the
//      caller can see exactly how old it is and say so. Blanking a panel on
//      one dropped request is worse - it looks like the metric went away.
//
//   3. An in-flight request is aborted when a newer one starts or the
//      component unmounts, so a slow query cannot land after the thing that
//      asked for it is gone.
// =============================================================================

import { onScopeDispose, ref, shallowRef, type Ref, type ShallowRef } from "vue";

export interface PollHandle<T> {
  /** Last successful value, or null before the first one lands. */
  data: ShallowRef<T | null>;
  /** Last error, cleared on the next success. */
  error: ShallowRef<unknown>;
  /** True while a request is in flight, including the first. */
  pending: Ref<boolean>;
  /** Unix seconds of the last SUCCESS. Not of the last attempt. */
  lastOk: Ref<number>;
  refresh: () => Promise<void>;
}

export function usePoll<T>(
  loader: (signal: AbortSignal) => Promise<T>,
  intervalMs: number,
): PollHandle<T> {
  const data = shallowRef<T | null>(null);
  const error = shallowRef<unknown>(null);
  const pending = ref(false);
  const lastOk = ref(Number.NaN);

  let controller: AbortController | null = null;
  let timer: number | undefined;
  let disposed = false;

  async function refresh(): Promise<void> {
    if (disposed) return;

    controller?.abort();
    const own = new AbortController();
    controller = own;
    pending.value = true;

    try {
      const next = await loader(own.signal);
      if (own.signal.aborted || disposed) return;
      data.value = next;
      error.value = null;
      lastOk.value = Date.now() / 1000;
    } catch (caught) {
      if (own.signal.aborted || disposed) return;
      // data is deliberately left alone. See (2) above.
      error.value = caught;
    } finally {
      if (controller === own) pending.value = false;
    }
  }

  function schedule(): void {
    stop();
    if (document.hidden) return;
    timer = window.setInterval(refresh, intervalMs);
  }

  function stop(): void {
    if (timer !== undefined) {
      window.clearInterval(timer);
      timer = undefined;
    }
  }

  function onVisibility(): void {
    if (document.hidden) {
      stop();
      controller?.abort();
    } else {
      void refresh();
      schedule();
    }
  }

  document.addEventListener("visibilitychange", onVisibility);
  void refresh();
  schedule();

  onScopeDispose(() => {
    disposed = true;
    stop();
    controller?.abort();
    document.removeEventListener("visibilitychange", onVisibility);
  });

  return { data, error, pending, lastOk, refresh };
}
