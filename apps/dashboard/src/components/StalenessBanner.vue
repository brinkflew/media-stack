<script setup lang="ts">
/**
 * The one component this dashboard would be dishonest without.
 *
 * Every number on every page arrives from something that can stop without
 * saying so - the hourly battery, the 30-second collector, the scrape. When
 * one of them does, the page keeps rendering the last value it saw, and a
 * frozen number is indistinguishable from a steady one. This strip is what
 * makes the difference visible, and it is deliberately the widest, loudest
 * element on the page when it appears.
 *
 * It renders nothing at all when everything is current, so it costs no space
 * in the normal case.
 */
import { computed } from "vue";
import { useHostStore } from "@/stores/host";
import { duration } from "@/format";
import StatusDot from "./StatusDot.vue";

const host = useHostStore();

interface Notice {
  tone: "warn" | "fail";
  title: string;
  detail: string;
}

const notices = computed<Notice[]>(() => {
  const out: Notice[] = [];

  if (host.signedOut) {
    out.push({
      tone: "fail",
      title: "signed out",
      detail: "the session expired and the passkey prompt could not be reached. Reload this page.",
    });
    // Nothing else can be true while this is: every other source is behind
    // the same sign-on, so they would all report the same thing.
    return out;
  }

  if (host.prometheusDown) {
    out.push({
      tone: "fail",
      title: "prometheus unreachable",
      detail: "every number on this page comes from it. What is shown is the last answer it gave.",
    });
    // The collector's freshness and the target list are both READ FROM
    // Prometheus, so with Prometheus down they are unknown rather than bad.
    // Reporting them anyway turns one fault into three notices, two of which
    // are consequences - which is exactly what Alertmanager's inhibit rules
    // exist to prevent, and the fastest way to make a banner unread.
  } else {
    if (host.targets.total > 0 && host.targets.up < host.targets.total) {
      out.push({
        tone: "fail",
        title: `${host.targets.total - host.targets.up} of ${host.targets.total} scrape targets down`,
        detail: "series behind a down target stop updating without disappearing.",
      });
    }

    const collector = host.collectorFreshness;
    if (collector.missing) {
      out.push({
        tone: "warn",
        title: "metrics collector has never reported",
        detail: "bin/collect-metrics.py writes the host series. Check home-server-metrics.timer.",
      });
    } else if (collector.stale) {
      out.push({
        tone: "fail",
        title: `metrics collector last ran ${duration(collector.age)} ago`,
        detail: "filesystems, container memory, GPU, disks and the check mirror are all frozen.",
      });
    }
  }

  if (host.statusNeverRun) {
    out.push({
      tone: "warn",
      title: "the check battery has never run here",
      detail: "bin/verify-host.sh has written no status.json. Check home-server-verify.timer.",
    });
  } else {
    const battery = host.statusFreshness;
    if (battery.missing) {
      out.push({
        tone: "warn",
        title: "check battery unreadable",
        detail: "status.json could not be fetched. Findings below are absent, not passing.",
      });
    } else if (battery.stale) {
      out.push({
        tone: "warn",
        title: `check battery last ran ${duration(battery.age)} ago`,
        detail: "it runs hourly. Every finding shown is from that run, not from now.",
      });
    }
  }

  return out;
});
</script>

<template>
  <div v-if="notices.length" class="banner">
    <div v-for="n in notices" :key="n.title" class="notice" :class="n.tone">
      <StatusDot :tone="n.tone" live :size="6" />
      <span class="title">{{ n.title }}</span>
      <span class="detail mono">{{ n.detail }}</span>
    </div>
  </div>
</template>

<style scoped>
.banner {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 12px var(--pad-page) 0;
}

.notice {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 9px 13px;
  border-radius: var(--r-sm);
  border: 1px solid;
}

.notice.warn {
  background: var(--warn-tint);
  border-color: var(--warn-edge);
}

.notice.fail {
  background: var(--fail-tint);
  border-color: var(--fail-edge);
}

.title {
  font: var(--t-ui-md);
  flex: none;
}

.detail {
  font: var(--t-mono-sm);
  color: var(--fg-4);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
