<script setup lang="ts">
/**
 * The segmentation and the traffic on it, drawn.
 *
 * LAYOUT IS COMPUTED, NOT HAND-PLACED. Inherited verbatim from the CSS version
 * this replaces, and still the constraint that matters: the design mocks this
 * up with absolute pixel coordinates, which look right once and then need
 * re-tuning every time a service is added - and a diagram that is expensive to
 * update is a diagram that stops being true. Every coordinate here comes out of
 * src/graph.ts, which reads src/topology.ts, which bin/lint-repo.sh holds to
 * stacks/.
 *
 * WHY IT IS BIPARTITE. A rail is a segment; a box is a container; the only line
 * carrying a measured number is the SPOKE between them. That is exactly the
 * shape of what the collector can measure - a container's bytes on a segment -
 * because per-flow accounting is unavailable on this host. A point-to-point
 * arrow with a rate on it would be a claim nothing supports, so there isn't one.
 *
 * Declared routes from paths.ts are a different language: they appear on hover
 * or focus, they are static, and they never animate. Reachability is asserted
 * by git; motion is asserted by measurement. Neither may borrow the other's
 * credibility.
 *
 * ASPECT-PRESERVING viewBox, unlike MetricChart. That component stretches
 * because a time series has no intrinsic aspect; a wiring diagram does, and
 * more to the point a stretched viewBox makes stroke-dashoffset advance at
 * different apparent speeds on horizontal and vertical spokes - so the same
 * rate would animate at two different speeds depending on direction.
 * vector-effect cannot rescue that; only preserving the aspect can.
 */
import { computed, ref } from "vue";
import { NETWORKS } from "@/topology";
import { PATHS, segmentsFor, tracePaths } from "@/paths";
import { LABEL_GUTTER, fitRole, flowDuration, intensity, layout, spokePath, type PlacedNode } from "@/graph";
import { useTooltip } from "@/composables/useTooltip";
import * as fmt from "@/format";
import type { Tone } from "@/types";

const props = defineProps<{
  tones: Map<string, Tone>;
  /** container|network -> bytes/sec. Absent key means NOT MEASURED. */
  rx: Map<string, number>;
  tx: Map<string, number>;
  /** False freezes every spoke. Motion is the claim "this is happening now". */
  flowing: boolean;
}>();

const tip = useTooltip();
const L = layout();
const focused = ref<string | null>(null);
const pinned = ref(false);

const railY = new Map(L.rails.map((r) => [r.id, r.y]));
const boxes = computed<PlacedNode[]>(() => (L.hub ? [...L.nodes, L.hub] : L.nodes));

function tone(name: string): Tone {
  return props.tones.get(name) ?? "off";
}

/** Absent is not zero. A container/segment pair nothing measured must render
 *  grey and still, never as an idle green link. */
function rate(container: string, network: string): { rx: number; tx: number } | null {
  const key = `${container}|${network}`;
  const r = props.rx.get(key);
  const t = props.tx.get(key);
  if (r === undefined && t === undefined) return null;
  return { rx: r ?? 0, tx: t ?? 0 };
}

function total(container: string, network: string): number {
  const r = rate(container, network);
  return r ? r.rx + r.tx : Number.NaN;
}

/** Two members means the spoke IS the edge - but only if neither talks past the
 *  bridge, which is a measurement rather than a property of the topology. */
function memberCount(network: string): number {
  return L.rails.find((r) => r.id === network)?.members ?? 0;
}

// --- the highlighted route ---------------------------------------------------
const lit = computed(() => {
  const node = focused.value;
  if (!node) return { nodes: new Set<string>(), edges: new Set<string>() };
  const nodes = new Set<string>();
  const edges = new Set<string>();
  for (const chain of tracePaths(node)) {
    for (let i = 0; i < chain.length; i += 1) {
      nodes.add(chain[i]);
      if (i > 0) edges.add(`${chain[i - 1]}>${chain[i]}`);
    }
  }
  return { nodes, edges };
});

function dim(name: string): boolean {
  return focused.value !== null && !lit.value.nodes.has(name);
}

/** Declared routes, drawn only while something is focused. Straight lines
 *  between box centres: they are a different language from the spokes on
 *  purpose, and routing them orthogonally would make them read as wiring. */
const routes = computed(() => {
  if (!focused.value) return [];
  const at = new Map(boxes.value.map((b) => [b.name, b]));
  return PATHS.filter((p) => lit.value.edges.has(`${p.from}>${p.to}`))
    .map((p) => {
      const a = at.get(p.from);
      const b = at.get(p.to);
      if (!a || !b) return null;
      return {
        key: `${p.from}>${p.to}`,
        x1: a.x + a.w / 2,
        y1: a.y + a.h / 2,
        x2: b.x + b.w / 2,
        y2: b.y + b.h / 2,
        runtime: p.source === "runtime",
      };
    })
    .filter((r): r is NonNullable<typeof r> => r !== null);
});

// --- tooltips ----------------------------------------------------------------
function nodeTip(n: PlacedNode) {
  const lines: string[] = [n.role];
  let caveat: string | undefined;
  for (const net of n.rails) {
    const r = rate(n.name, net);
    lines.push(
      r
        ? `${net}: ${fmt.rate(r.rx)} in / ${fmt.rate(r.tx)} out`
        : `${net}: not measured`,
    );
  }
  if (n.members.length) {
    lines.push(`holds the namespace for ${n.members.map((m) => m.name).join(", ")}`);
    caveat = "One number for all four. They share one namespace, so per-container series do not exist here.";
  } else if (n.rails.some((net) => memberCount(net) > 2)) {
    caveat = "These are this container's totals on each segment. Which peer they went to is not measured.";
  }
  if (n.name === "caddy") lines.push("the only container on more than one segment");
  return { title: n.name, lines, caveat };
}

function railTip(id: string) {
  const r = L.rails.find((x) => x.id === id);
  const net = NETWORKS.find((x) => x.id === id);
  const lines = [
    net?.purpose ?? "",
    `${r?.members ?? 0} member(s)`,
    "Options=isolate=true",
  ];
  return {
    title: id,
    lines,
    caveat:
      (r?.members ?? 0) > 2
        ? "Each container's total on this segment is measured; the split between peers is not."
        : r?.detached
          ? "caddy is not on this segment. That absence is the security model, not an omission."
          : undefined,
  };
}

function spokeTip(n: PlacedNode, net: string) {
  const r = rate(n.name, net);
  const members = memberCount(net);
  return {
    title: `${n.name} on ${net}`,
    lines: r
      ? [`${fmt.rate(r.rx)} received`, `${fmt.rate(r.tx)} sent`, `${members} member(s) on this segment`]
      : ["not measured", `${members} member(s) on this segment`],
    caveat:
      !r
        ? "No series covers this pair. Absent is not idle."
        : members > 2
          ? `This is ${n.name}'s total on ${net}, not traffic to any one peer. Per-flow accounting is not available on this host.`
          : undefined,
  };
}

// --- keyboard ----------------------------------------------------------------
// ONE tab stop, then arrows. Twenty boxes plus thirty spokes as individual
// stops would put fifty between this panel and the next, which is worse than no
// keyboard access at all.
const order = computed(() => boxes.value.map((b) => b.name));

function move(delta: number): void {
  const list = order.value;
  const i = focused.value ? list.indexOf(focused.value) : -1;
  focused.value = list[(i + delta + list.length) % list.length] ?? list[0];
}

function onKey(e: KeyboardEvent): void {
  if (e.key === "ArrowRight" || e.key === "ArrowDown") {
    move(1);
    e.preventDefault();
  } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
    move(-1);
    e.preventDefault();
  } else if (e.key === "Enter" || e.key === " ") {
    pinned.value = !pinned.value;
    e.preventDefault();
  } else if (e.key === "Escape") {
    if (pinned.value) pinned.value = false;
    else focused.value = null;
    tip.closeAll();
  }
}

function enter(name: string, el: EventTarget | null, content: ReturnType<typeof nodeTip>): void {
  if (!pinned.value) focused.value = name;
  if (el) tip.show(`net-${name}`, el as SVGElement, content, 250);
}
function leave(name: string): void {
  if (!pinned.value) focused.value = null;
  tip.hide(`net-${name}`, 80);
}

const summary = computed(() => {
  const exact = PATHS.filter((p) => {
    const segs = segmentsFor(p);
    return segs.length === 1 && memberCount(segs[0]) === 2;
  }).length;
  return `${PATHS.length} declared routes, ${exact} on a segment with only two members`;
});
</script>

<template>
  <div class="wrap">
    <svg
      :viewBox="`0 0 ${L.width} ${L.height}`"
      preserveAspectRatio="xMidYMid meet"
      class="graph"
      tabindex="0"
      role="img"
      :aria-label="`network topology: ${L.nodes.length + 1} containers across ${L.rails.length} isolated bridges. ${summary}`"
      @keydown="onKey"
    >
      <!-- rails: one per segment, in topology.ts declaration order -->
      <g v-for="r in L.rails" :key="r.id">
        <line
          :x1="LABEL_GUTTER - 8"
          :y1="r.y"
          :x2="L.width - 16"
          :y2="r.y"
          :stroke="r.detached ? 'var(--line-faint)' : 'var(--line)'"
          stroke-width="1"
          :stroke-dasharray="r.detached ? '2 5' : ''"
          vector-effect="non-scaling-stroke"
        />
        <text
          :x="8"
          :y="r.y + 3"
          class="rail-label"
          v-bind="tip.bind(`rail-${r.id}`, railTip(r.id))"
        >{{ r.id }}</text>
        <text v-if="r.detached" :x="8" :y="r.y + 14" class="rail-note">no proxy route</text>
      </g>

      <!-- declared routes, only while something is focused -->
      <g v-if="routes.length" class="routes">
        <line
          v-for="r in routes"
          :key="r.key"
          :x1="r.x1"
          :y1="r.y1"
          :x2="r.x2"
          :y2="r.y2"
          stroke="var(--ok)"
          stroke-width="1"
          :stroke-dasharray="r.runtime ? '3 3' : ''"
          opacity="0.5"
          vector-effect="non-scaling-stroke"
        />
      </g>

      <!-- spokes: the ONLY lines carrying a measured number -->
      <g v-for="n in boxes" :key="`s-${n.name}`">
        <g v-for="net in n.rails" :key="`${n.name}-${net}`">
          <path
            :d="spokePath(n, railY.get(net) ?? 0, n.name === 'caddy')"
            fill="none"
            :stroke="total(n.name, net) > 0 ? 'var(--ok)' : 'var(--fg-dim)'"
            :stroke-width="Number.isFinite(total(n.name, net)) ? 1.4 : 2"
            :stroke-dasharray="Number.isFinite(total(n.name, net)) ? '6 10' : '3 4'"
            :class="{ flow: flowing && intensity(total(n.name, net)) > 0 }"
            :style="{
              animationDuration: `${flowDuration(total(n.name, net))}s`,
              opacity: dim(n.name) ? 0.15 : 0.35 + intensity(total(n.name, net)) * 0.5,
            }"
            vector-effect="non-scaling-stroke"
            v-bind="tip.bind(`spoke-${n.name}-${net}`, spokeTip(n, net))"
          />
          <!-- The magnitude tick. Drawn in BOTH modes, deliberately: it is the
               reduced-motion encoding, and it is also the only thing that makes
               a rate visible in fixtures/shoot.mjs, which takes still PNGs and
               is the only visual review this repo has. -->
          <rect
            v-if="intensity(total(n.name, net)) > 0"
            :x="n.name === 'caddy' ? n.x + n.w + 4 : n.x + n.w / 2 - 1"
            :y="n.name === 'caddy' ? (railY.get(net) ?? 0) - 1.5 : ((railY.get(net) ?? 0) + n.y + n.h / 2) / 2 - 1.5"
            :width="2 + intensity(total(n.name, net)) * 10"
            height="3"
            rx="1.5"
            fill="var(--ok)"
            :opacity="dim(n.name) ? 0.2 : 0.85"
          />
        </g>
      </g>

      <!-- boxes -->
      <g
        v-for="n in boxes"
        :key="n.name"
        class="node"
        :class="{ dim: dim(n.name), lit: focused === n.name }"
        v-bind="tip.bind(`net-${n.name}`, nodeTip(n))"
        @pointerenter="enter(n.name, $event.currentTarget, nodeTip(n))"
        @pointerleave="leave(n.name)"
        @focus="focused = n.name"
      >
        <rect
          :x="n.x"
          :y="n.y"
          :width="n.w"
          :height="n.h"
          rx="6"
          fill="var(--surface-high)"
          :stroke="focused === n.name ? 'var(--ok)' : 'var(--line-strong)'"
          :stroke-width="focused === n.name ? 1.5 : 1"
          vector-effect="non-scaling-stroke"
        />
        <circle :cx="n.x + 11" :cy="n.y + 13" r="3" :fill="`var(--${tone(n.name)})`" />
        <text :x="n.x + 20" :y="n.y + 16" class="node-name">{{ n.name }}</text>
        <text :x="n.x + 9" :y="n.y + 27" class="node-role">{{ fitRole(n.role) }}</text>

        <!-- the pod, nested: drawn inside because that is what makes the
             kill-switch structural rather than a rule somebody remembers -->
        <g v-if="n.members.length">
          <rect
            :x="n.x + 6"
            :y="n.y + n.h - 4"
            :width="n.w - 12"
            :height="n.members.length * 12 + 6"
            rx="4"
            fill="oklch(0 0 0 / 0.25)"
            stroke="var(--line-strong)"
            stroke-dasharray="2 3"
            vector-effect="non-scaling-stroke"
          />
          <g v-for="(m, i) in n.members" :key="m.name">
            <circle :cx="n.x + 14" :cy="n.y + n.h + 6 + i * 12" r="2.5" :fill="`var(--${tone(m.name)})`" />
            <text :x="n.x + 21" :y="n.y + n.h + 9 + i * 12" class="pod-name">{{ m.name }}</text>
          </g>
        </g>
      </g>
    </svg>

    <p class="legend mono">
      Every bridge carries <span class="lit">Options=isolate=true</span>, so a container on one rail
      has no route to another. A spoke is a container's measured traffic on a segment - not traffic
      to any one peer, which is not measurable here. {{ summary }}.
      <span v-if="!flowing" class="frozen"> Motion is stopped: these rates are not current.</span>
    </p>
  </div>
</template>

<style scoped>
.wrap {
  min-width: 0;
}

.graph {
  width: 100%;
  height: auto;
  display: block;
  overflow: visible;
}

.graph:focus-visible {
  outline: 2px solid var(--ok);
  outline-offset: 3px;
  border-radius: var(--r-sm);
}

.rail-label {
  font: var(--t-mono-xs);
  fill: var(--fg-5);
  cursor: default;
}

.rail-note {
  font: var(--t-mono-xs);
  fill: var(--fg-dim);
}

.node {
  cursor: default;
  transition: opacity 120ms linear;
}

.node.dim {
  opacity: 0.25;
}

.node-name {
  font: var(--t-mono-md);
  fill: var(--fg-2);
}

.node-role {
  font: var(--t-mono-xs);
  fill: var(--fg-dim);
}

.pod-name {
  font: var(--t-mono-xs);
  fill: var(--fg-4);
}

.legend {
  margin-top: 12px;
  padding-top: 10px;
  border-top: 1px solid var(--line);
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.lit {
  color: var(--fg-3);
}

.frozen {
  color: var(--warn);
}
</style>
