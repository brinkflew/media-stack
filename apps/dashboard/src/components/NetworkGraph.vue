<script setup lang="ts">
/**
 * The segmentation, drawn.
 *
 * LAYOUT IS COMPUTED, NOT HAND-PLACED. The design mocks this up with absolute
 * pixel coordinates, which look right once and then need re-tuning every time a
 * service is added - and a diagram that is expensive to update is a diagram
 * that stops being true. Here the bands are laid out from src/topology.ts, so
 * adding a network is one entry in that array.
 *
 * The shape it draws is the architecture's actual claim: Caddy is the only
 * thing that joins more than one segment, every bridge carries isolate=true, so
 * a member of one band has no route to a member of another. Colour is live -
 * it comes from home_server_container_health - and the shape is static, because
 * the shape is defined in git.
 */
import { computed } from "vue";
import { NETWORKS, NODES, podMembers, type Node } from "@/topology";
import StatusDot from "./StatusDot.vue";

const props = defineProps<{
  /** container name -> tone. Absent means "no health check defined". */
  tones: Map<string, "ok" | "warn" | "fail" | "off">;
}>();

const HUB = "caddy";

interface Band {
  id: string;
  purpose: string;
  members: Node[];
  /** Caddy joins this segment, so there is an edge to draw. */
  joined: boolean;
}

const bands = computed<Band[]>(() =>
  NETWORKS.map((net) => ({
    id: net.id,
    purpose: net.purpose,
    members: NODES.filter((n) => n.name !== HUB && n.networks.includes(net.id)),
    joined: NODES.find((n) => n.name === HUB)?.networks.includes(net.id) ?? false,
  })),
);

function tone(name: string): "ok" | "warn" | "fail" | "off" {
  return props.tones.get(name) ?? "off";
}

const hubTone = computed(() => tone(HUB));

/** The one segment Caddy is deliberately NOT on. Worth stating rather than
 *  leaving as an absence somebody has to notice. */
const unjoined = computed(() => bands.value.filter((b) => !b.joined).map((b) => b.id));
</script>

<template>
  <div class="graph">
    <div class="hub">
      <div class="hub-node">
        <div class="hub-head">
          <StatusDot :tone="hubTone" :size="6" glow />
          <span class="hub-name">caddy</span>
        </div>
        <div class="hub-sub mono">the only multi-homed container</div>
        <div class="hub-ports mono">80, 443 published</div>
      </div>
      <div class="spine" />
    </div>

    <div class="bands">
      <div v-for="band in bands" :key="band.id" class="band" :class="{ detached: !band.joined }">
        <span class="connector" :class="{ off: !band.joined }" />

        <div class="band-head">
          <span class="band-name mono">{{ band.id }}</span>
          <span class="band-purpose mono">{{ band.purpose }}</span>
          <span v-if="!band.joined" class="band-note mono">no proxy route</span>
        </div>

        <div class="members">
          <div v-for="m in band.members" :key="m.name" class="member">
            <div class="member-head">
              <StatusDot :tone="tone(m.name)" :size="5" />
              <span class="member-name">{{ m.name }}</span>
            </div>
            <div class="member-role mono">{{ m.role }}</div>

            <!-- The pod: three containers with no network stack of their own,
                 living inside gluetun's namespace. Drawn nested because that
                 is what makes the kill-switch structural rather than a rule. -->
            <div v-if="podMembers(m.name).length" class="pod">
              <div v-for="p in podMembers(m.name)" :key="p.name" class="pod-member">
                <StatusDot :tone="tone(p.name)" :size="4" />
                <span class="pod-name mono">{{ p.name }}</span>
                <span class="pod-role mono truncate">{{ p.role }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <p v-if="unjoined.length" class="legend mono">
      Every bridge carries Options=isolate=true, so a member of one band has no route to a member of
      another. {{ unjoined.join(", ") }} has no proxy route by design.
    </p>
  </div>
</template>

<style scoped>
.graph {
  display: grid;
  grid-template-columns: 210px 1fr;
  gap: 0 18px;
  align-items: start;
}

.hub {
  position: sticky;
  top: 12px;
  display: grid;
  grid-template-rows: auto 1fr;
}

.hub-node {
  padding: 11px 12px;
  border-radius: var(--r-sm);
  background: var(--surface-high);
  border: 1px solid var(--line-strong);
  border-left: 2px solid var(--ok);
  box-shadow: var(--shadow-node);
}

.hub-head {
  display: flex;
  align-items: center;
  gap: 8px;
}

.hub-name {
  font: var(--t-ui-md);
}

.hub-sub,
.hub-ports {
  font: var(--t-mono-xs);
  color: var(--fg-5);
  margin-top: 4px;
}

.spine {
  width: 1px;
  margin: 8px auto 0;
  background: linear-gradient(var(--line-strong), transparent);
}

.bands {
  display: flex;
  flex-direction: column;
  gap: 12px;
  min-width: 0;
}

.band {
  position: relative;
  padding: 14px 13px 12px;
  border: 1px dashed var(--line-strong);
  border-radius: var(--r-sm);
  background: oklch(1 0 0 / 0.018);
  min-width: 0;
}

.band.detached {
  border-style: dotted;
  opacity: 0.85;
}

/* The edge from Caddy. A dashed teal line where a route exists, nothing but a
   stub where it does not - net-solver and net-egress have no proxy route, and
   that absence is a security property rather than an omission. */
.connector {
  position: absolute;
  left: -18px;
  top: 22px;
  width: 18px;
  height: 1px;
  background: repeating-linear-gradient(90deg, var(--ok) 0 3px, transparent 3px 6px);
  opacity: 0.75;
}

.connector.off {
  background: repeating-linear-gradient(90deg, var(--off) 0 2px, transparent 2px 5px);
}

.band-head {
  display: flex;
  align-items: baseline;
  gap: 9px;
  margin-bottom: 10px;
}

.band-name {
  font: var(--t-mono-md);
  color: var(--fg-2);
}

.band-purpose {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.band-note {
  margin-left: auto;
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.members {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.member {
  flex: 1 1 165px;
  min-width: 0;
  max-width: 260px;
  padding: 8px 10px;
  border-radius: var(--r-sm);
  background: var(--surface-high);
  border: 1px solid var(--line-strong);
  box-shadow: var(--shadow-node);
}

.member-head {
  display: flex;
  align-items: center;
  gap: 8px;
}

.member-name {
  font: var(--t-ui-sm);
  font-weight: 500;
}

.member-role {
  font: var(--t-mono-xs);
  color: var(--fg-5);
  margin-top: 3px;
  /* Wrap rather than truncate: the role is the only thing on the card that
     says what the node is for, and half of it is worse than two lines. */
  overflow-wrap: anywhere;
}

.pod {
  margin-top: 8px;
  padding: 7px 8px;
  border-radius: var(--r-xs);
  border: 1px dashed var(--line-strong);
  background: oklch(0 0 0 / 0.18);
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.pod-member {
  display: flex;
  align-items: center;
  gap: 7px;
  min-width: 0;
}

.pod-name {
  font: var(--t-mono-xs);
  color: var(--fg-3);
  flex: none;
}

.pod-role {
  font: var(--t-mono-xs);
  color: var(--fg-dim);
}

.legend {
  grid-column: 1 / -1;
  margin-top: 14px;
  padding-top: 12px;
  border-top: 1px solid var(--line);
  font: var(--t-mono-sm);
  color: var(--fg-5);
}
</style>
