// =============================================================================
// The range picker
// -----------------------------------------------------------------------------
// Each window carries its own step, chosen so every one of them lands between
// 120 and 340 points. That is deliberate on both sides: fewer and a spike lasting
// one scrape disappears into a straight line; many more and the chart is drawing
// several points per pixel, which costs bandwidth and renders identically.
//
// The 1h window steps at 30s, which is the scrape interval - asking for finer
// than the data exists only interpolates.
// =============================================================================

import { computed, ref } from "vue";

export interface TimeWindow {
  id: string;
  label: string;
  seconds: number;
  step: number;
}

export const WINDOWS: TimeWindow[] = [
  { id: "1h", label: "1h", seconds: 3600, step: 30 },
  { id: "6h", label: "6h", seconds: 6 * 3600, step: 120 },
  { id: "24h", label: "24h", seconds: 24 * 3600, step: 300 },
  { id: "7d", label: "7d", seconds: 7 * 86400, step: 1800 },
];

const STORAGE_KEY = "home-server.window";
const DEFAULT_ID = "6h";

function restore(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    return WINDOWS.some((w) => w.id === saved) ? (saved as string) : DEFAULT_ID;
  } catch {
    return DEFAULT_ID;
  }
}

// Module-level, so the choice survives a route change and both pages agree.
const active = ref(restore());

export function useTimeWindow() {
  const current = computed(() => WINDOWS.find((w) => w.id === active.value) ?? WINDOWS[1]);

  function setWindow(id: string): void {
    if (!WINDOWS.some((w) => w.id === id)) return;
    active.value = id;
    try {
      localStorage.setItem(STORAGE_KEY, id);
    } catch {
      // Storage unavailable. The choice still applies for this session.
    }
  }

  return { window: current, windows: WINDOWS, active, setWindow };
}
