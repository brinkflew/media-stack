<script setup lang="ts">
/**
 * The media stack as a row of chips, along the bottom of Home.
 *
 * Ten containers rather than all twenty-three: this is the media stack, and the
 * infrastructure has a whole page of its own. STRIP_SERVICES in @/media is that
 * list, and it is checked against @/topology at startup in dev so a container
 * renamed in stacks/ shows up as a warning rather than as a chip that silently
 * stops appearing.
 *
 * THE TALLY HAS FOUR TERMS, WHICH IS ONE MORE THAN THE DESIGN. unpackerr defines
 * no health check, so home_server_container_health is ABSENT for it rather than
 * zero - and tokens.css is explicit that grey is never green. Folding "nobody is
 * checking" into "healthy" would report a verified-good container on the strength
 * of no evidence, which is the failure this whole repository is written around.
 * Zero terms are dropped, the way NavBar's tally already does.
 */
import { computed } from "vue";

import PanelBox from "@/components/PanelBox.vue";
import StatusDot from "@/components/StatusDot.vue";
import ChipLink from "@/components/ChipLink.vue";

import { usePoll } from "@/composables/usePoll";
import { useMetricsStale } from "@/composables/useStaleness";
import { instantBy } from "@/api/prometheus";
import { SERVICES } from "@/queries";
import { containerTone } from "@/health";
import { STRIP_SERVICES } from "@/media";
import { appHome } from "@/links";
import { nodeByName } from "@/topology";
import type { Tone } from "@/types";

const metricsStale = useMetricsStale();

// A second hand-maintained list is the shape CLAUDE.md calls the most driftable
// thing here, so it gets the uncovered() treatment: dev-only, loud, once.
if (import.meta.env.DEV) {
  for (const s of STRIP_SERVICES) {
    if (!nodeByName(s.container)) {
      console.warn(`[strip] ${s.container} is not in src/topology.ts - renamed in stacks/?`);
    }
  }
}

const health = usePoll(async (signal) => {
  const [running, state] = await Promise.all([
    instantBy(SERVICES.running, "container", signal),
    instantBy(SERVICES.health, "container", signal),
  ]);
  return STRIP_SERVICES.map((s) => ({
    ...s,
    // `undefined` here means the series is absent, which containerTone reads as
    // "unchecked". `?? 0` would be exactly the bug that comment warns about.
    ...containerTone((running.get(s.container) ?? 0) === 1, state.get(s.container)),
    href: s.app ? appHome(s.app) : null,
  }));
}, 30_000);

const chips = computed(() => health.data.value ?? []);

const tally = computed(() => {
  const counts: Record<Tone, number> = { ok: 0, warn: 0, fail: 0, off: 0 };
  for (const c of chips.value) counts[c.tone] += 1;
  const parts: string[] = [];
  if (counts.ok) parts.push(`${counts.ok} healthy`);
  if (counts.warn) parts.push(`${counts.warn} degraded`);
  if (counts.fail) parts.push(`${counts.fail} failing`);
  if (counts.off) parts.push(`${counts.off} unchecked`);
  return parts.join(" / ");
});
</script>

<template>
  <PanelBox label="Services" sunken :stale="metricsStale" padding="11px">
    <template #aside>
      <span class="mono tally">{{ tally }}</span>
    </template>

    <div class="chips">
      <ChipLink
        v-for="c in chips"
        :key="c.container"
        :label="c.label"
        :href="c.href"
        :title="`${c.container}: ${c.state}`"
        :tone="c.tone === 'ok' ? 'ok' : 'off'"
      >
        <template #lead>
          <!-- 1.6s rather than the design's 1.4s: one motion vocabulary beats
               matching a difference nobody can perceive. StatusDot's own pulse
               is what the rest of the application uses. -->
          <StatusDot :tone="c.tone" :live="c.tone === 'fail'" :size="5" />
        </template>
      </ChipLink>
    </div>
  </PanelBox>
</template>

<style scoped>
.tally {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
</style>
