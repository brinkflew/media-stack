<script setup lang="ts">
/**
 * The shell header: wordmark, the four pages, and a per-page toolbar.
 *
 * All four routes exist even though two are stubs, because the shell is what
 * this first cut is meant to prove. A stub says what it will read and that it
 * is not built; it does not render an empty panel that looks like a working
 * page with no data.
 */
import { computed } from "vue";
import { useHostStore } from "@/stores/host";
import { coarse } from "@/format";
import StatusDot from "./StatusDot.vue";

const host = useHostStore();

const routes = [
  { to: "/home", label: "Home" },
  { to: "/library", label: "Library" },
  { to: "/services", label: "Services" },
  { to: "/system", label: "System" },
];

const tone = computed(() => {
  switch (host.verdict) {
    case "pass":
      return "ok" as const;
    case "warn":
      return "warn" as const;
    case "fail":
      return "fail" as const;
    default:
      return "off" as const;
  }
});

/** The counts, or an honest blank. Never "0 failing" when nothing was read. */
const tally = computed(() => {
  if (host.verdict === "unknown" || !host.doc) return "no reading";
  const s = host.doc.summary;
  if (s.fail === 0 && s.warn === 0) return `${s.pass} passing`;
  return [s.fail ? `${s.fail} failing` : "", s.warn ? `${s.warn} degraded` : ""]
    .filter(Boolean)
    .join(" / ");
});

const age = computed(() => {
  const f = host.statusFreshness;
  return f.missing ? "never" : coarse(f.age);
});
</script>

<template>
  <header class="bar">
    <div class="left">
      <RouterLink to="/system" class="mark" aria-label="home server">
        <span class="glyph" />
        <span class="word mono">HOMESERVER</span>
      </RouterLink>

      <nav class="nav">
        <RouterLink v-for="r in routes" :key="r.to" :to="r.to" class="tab">
          {{ r.label }}
        </RouterLink>
      </nav>
    </div>

    <div class="right">
      <!-- Pages teleport their own controls here. `defer` so the target is
           mounted before a page that renders early tries to reach it. -->
      <div id="toolbar" class="toolbar" />

      <div class="verdict" :class="tone">
        <StatusDot :tone="tone" :live="tone === 'fail'" :size="5" />
        <span class="mono">{{ tally }}</span>
        <span class="age mono">{{ age }}</span>
      </div>
    </div>
  </header>
</template>

<style scoped>
.bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 22px;
  padding: 15px var(--pad-page);
  border-bottom: 1px solid var(--line);
}

.left,
.right {
  display: flex;
  align-items: center;
  gap: 22px;
  min-width: 0;
}

.right {
  gap: 10px;
}

.mark {
  display: flex;
  align-items: center;
  gap: 9px;
  color: var(--fg);
  flex: none;
}

.glyph {
  width: 20px;
  height: 20px;
  border-radius: 6px;
  background: var(--ok);
}

.word {
  font: 600 11px/1 var(--font-mono);
  letter-spacing: 0.16em;
}

.nav {
  display: flex;
  gap: 3px;
}

.tab {
  padding: 6px 12px;
  border-radius: var(--r-sm);
  font: var(--t-ui);
  color: var(--fg-4);
}

.tab:hover {
  background: oklch(1 0 0 / 0.05);
  color: var(--fg);
}

.tab.router-link-active {
  background: oklch(1 0 0 / 0.07);
  color: var(--fg);
  font-weight: 500;
}

.toolbar {
  display: flex;
  align-items: center;
  gap: 10px;
}

.verdict {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 5px 11px;
  border-radius: var(--r-sm);
  font: var(--t-mono-md);
  border: 1px solid var(--line);
  background: var(--fill);
  color: var(--fg-3);
  flex: none;
}

.verdict.ok {
  background: var(--ok-tint);
  border-color: var(--ok-edge);
  color: var(--ok);
}

.verdict.warn {
  background: var(--warn-tint);
  border-color: var(--warn-edge);
  color: var(--warn);
}

.verdict.fail {
  background: var(--fail-tint);
  border-color: var(--fail-edge);
  color: var(--fail-text);
}

.age {
  color: var(--fg-dim);
  font-weight: 400;
}
</style>
