<script setup lang="ts">
/**
 * Network: the segmentation, the routes across it, and the traffic on it.
 *
 * Split out of Services because the two answer different questions. Services
 * asks "is this container healthy"; this page asks "what can reach what, and
 * what is actually moving" - and the second needed a data layer before it could
 * be drawn at all.
 *
 * THERE IS NO WindowPicker HERE, deliberately. Every number on this page is an
 * instant query over rate(...[5m]); the 1h/6h/24h/7d control would change
 * nothing on screen, and a control that does nothing is a lie about a control.
 * It comes back the day this page grows a traffic-over-time lane.
 */
import { computed } from "vue";

import PanelBox from "@/components/PanelBox.vue";
import NetworkGraph from "@/components/NetworkGraph.vue";
import StaleNote from "@/components/StaleNote.vue";

import { usePoll } from "@/composables/usePoll";
import { useMetricsStale } from "@/composables/useStaleness";
import { useTooltip } from "@/composables/useTooltip";
import { containerTone } from "@/health";
import type { Tone } from "@/types";
import { instant, instantBy, value } from "@/api/prometheus";
import { NETWORK, SERVICES } from "@/queries";
import { NETWORKS, PUBLISHED } from "@/topology";
import { PATHS } from "@/paths";
import * as fmt from "@/format";

const tip = useTooltip();
const metricsStale = useMetricsStale();

/** The graph colours its boxes live. Services gets this from its rack; this
 *  page has no rack, so it asks for the same two series directly - the shape
 *  ServiceStrip already uses. `health` stays undefined when absent: a container
 *  with no health check defined must not read as verified-healthy. */
const net = usePoll(async (signal) => {
  const [running, health, rx, tx, unmapped] = await Promise.all([
    instantBy(SERVICES.running, "container", signal),
    instantBy(SERVICES.health, "container", signal),
    instant(NETWORK.rx, signal),
    instant(NETWORK.tx, signal),
    instant(NETWORK.unmapped, signal),
  ]);

  const tones = new Map<string, Tone>();
  for (const [name, up] of running) {
    tones.set(name, containerTone(up === 1, health.get(name)).tone);
  }

  // Keyed on the PAIR, because neither instantBy nor a single label can express
  // it. Neither a container name nor a network name may contain "|".
  const pair = (series: typeof rx): Map<string, number> => {
    const out = new Map<string, number>();
    for (const s of series) {
      const c = s.metric.container;
      const n = s.metric.network;
      if (c && n) out.set(`${c}|${n}`, value(s.value));
    }
    return out;
  };

  return {
    tones,
    rx: pair(rx),
    tx: pair(tx),
    unmapped: value(unmapped[0]?.value),
  };
}, 30_000);

const tones = computed(() => net.data.value?.tones ?? new Map<string, Tone>());
const rx = computed(() => net.data.value?.rx ?? new Map<string, number>());
const tx = computed(() => net.data.value?.tx ?? new Map<string, number>());

/**
 * MOTION IS THE CLAIM "THIS IS HAPPENING NOW", so a stale reading must stop it.
 * Dimming alone is not enough: the eye reads movement long before it reads
 * opacity, so a dimmed animation still asserts liveness. Three poll intervals
 * of slack, measured against usePoll's own lastOk - which it deliberately does
 * not advance on a failed poll, and which is already stale when a hidden tab
 * comes back, so the frozen state is reached before the first frame renders.
 */
const flowing = computed(() => {
  if (metricsStale.value) return false;
  const at = net.lastOk.value;
  if (!Number.isFinite(at)) return false;
  return Date.now() / 1000 - at < 90;
});

/** Per-segment totals, from the same pair map. Summed over members, so it
 *  double-counts every intra-segment byte - once as a sender's transmit and
 *  once as the receiver's receive. Reported as "seen on" rather than as a
 *  throughput for exactly that reason. */
const perSegment = computed(() =>
  NETWORKS.map((n) => {
    let bytes = 0;
    let measured = false;
    for (const [key, v] of rx.value) {
      if (key.endsWith(`|${n.id}`)) {
        bytes += v;
        measured = true;
      }
    }
    for (const [key, v] of tx.value) {
      if (key.endsWith(`|${n.id}`)) bytes += v;
    }
    return { id: n.id, purpose: n.purpose, bytes, measured };
  }),
);

const tunnel = computed(() => {
  const r = rx.value.get("torrent-infra|tunnel");
  const t = tx.value.get("torrent-infra|tunnel");
  return r === undefined && t === undefined ? null : { rx: r ?? 0, tx: t ?? 0 };
});
</script>

<template>
  <div class="page">
    <Teleport defer to="#toolbar">
      <span class="mono note">read only</span>
    </Teleport>

    <section class="head">
      <span class="label">Network</span>
      <span class="mono counts">
        {{ NETWORKS.length }} bridges, all isolate=true / {{ PATHS.length }} declared routes /
        {{ PUBLISHED.length }} published ports
      </span>
    </section>

    <StaleNote :reason="metricsStale" />

    <section class="lower">
      <PanelBox label="Segments and traffic" :stale="metricsStale">
        <template #aside>
          <span>hover or focus a container to trace its routes</span>
        </template>
        <NetworkGraph :tones="tones" :rx="rx" :tx="tx" :flowing="flowing" />
      </PanelBox>

      <div class="side">
        <PanelBox label="Seen on each segment" :stale="metricsStale">
          <ul class="segs">
            <li v-for="s in perSegment" :key="s.id" class="seg mono">
              <span class="sname">{{ s.id }}</span>
              <span class="sval" :class="{ absent: !s.measured }">
                {{ s.measured ? fmt.rate(s.bytes) : "not measured" }}
              </span>
            </li>
          </ul>
          <p class="hint mono">
            Both directions of every member, added up - so an intra-segment byte is counted twice,
            once as a send and once as the matching receive. It is a measure of how busy a bridge is,
            not of throughput across it.
          </p>
        </PanelBox>

        <PanelBox label="Egress" :stale="metricsStale">
          <div class="apps mono">
            <div class="app">
              <span
                v-bind="
                  tip.bind('egress-tunnel', {
                    title: 'the VPN tunnel',
                    lines: [
                      'gluetun\'s tun0, inside the torrent pod',
                      'every byte qBittorrent and JOAL have moved',
                    ],
                    caveat:
                      'The pod has no other route out, which is what makes the kill-switch structural rather than a firewall rule.',
                  })
                "
                >tunnel</span
              >
              <span class="av">
                {{ tunnel ? `${fmt.rate(tunnel.rx)} / ${fmt.rate(tunnel.tx)}` : "not measured" }}
              </span>
            </div>
          </div>
          <p class="hint mono">
            The only place the pod's egress is visible. gluetun, qBittorrent and JOAL share one
            network namespace, so there is one set of counters for all three and no per-container
            split exists to report.
          </p>
        </PanelBox>

        <PanelBox label="Published ports">
          <template #aside>
            <span>{{ PUBLISHED.length }} in the whole stack</span>
          </template>
          <ul class="ports">
            <li
              v-for="p in PUBLISHED"
              :key="`${p.node}-${p.mapping}`"
              class="port mono"
              v-bind="
                tip.bind(`port-${p.node}-${p.mapping}`, {
                  title: p.mapping,
                  lines: [p.node, 'the only way in that does not go through a bridge'],
                  caveat:
                    'firewalld governs this separately. A publish with no matching rule is a closed port on a container that looks perfectly healthy.',
                })
              "
            >
              <span class="pmap">{{ p.mapping }}</span>
              <span class="pnode">{{ p.node }}</span>
            </li>
          </ul>
          <p class="hint mono">
            Everything else is reached by container name over its own bridge.
          </p>
        </PanelBox>
      </div>
    </section>

    <p v-if="(net.data.value?.unmapped ?? 0) > 0" class="unmapped mono">
      {{ net.data.value?.unmapped }} interface(s) matched no podman network and are not a tunnel, so
      their traffic is absent from this page. That is what
      home_server_container_network_unmapped_interfaces counts.
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

.note {
  font: var(--t-mono-sm);
  color: var(--fg-dim);
}

.head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
}

.counts {
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.lower {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 320px;
  gap: 10px;
  align-items: start;
}

.side {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.segs,
.ports {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.seg,
.port {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 9px;
  padding: 5px 4px;
  border-radius: var(--r-xs);
  font: var(--t-mono-sm);
}

.port {
  grid-template-columns: 92px 1fr;
}

.seg:hover,
.port:hover {
  background: oklch(1 0 0 / 0.04);
}

.sname,
.pmap {
  color: var(--fg-2);
}

.sval {
  color: var(--fg-3);
}

/* Absent is not zero, and it must not look like a small number. */
.absent {
  color: var(--fg-dim);
}

.pnode {
  color: var(--fg-5);
}

.hint {
  margin-top: 10px;
  padding-top: 9px;
  border-top: 1px solid var(--line);
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.apps {
  display: flex;
  flex-direction: column;
  gap: 7px;
}

.app {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.av {
  color: var(--fg-2);
  font-weight: 500;
}

.unmapped {
  font: var(--t-mono-sm);
  color: var(--warn);
}

@media (max-width: 1400px) {
  .lower {
    grid-template-columns: 1fr;
  }

  .side {
    flex-direction: row;
  }

  .side > * {
    flex: 1;
  }
}
</style>
