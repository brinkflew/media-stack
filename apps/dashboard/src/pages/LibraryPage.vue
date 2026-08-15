<script setup lang="ts">
import StubPage from "@/components/StubPage.vue";

/**
 * The per-file view, which is the largest of the four and the one whose data
 * is furthest away. Tdarr's queue is already a metric, but only as a count by
 * verdict - CLAUDE.md is explicit that pulling jobsjsondb per file "costs more
 * than it tells anyone", so a file table needs a deliberate collector rather
 * than a wider query.
 */
const sources = [
  {
    name: "Sonarr, Radarr /queue",
    detail: "what is downloading, what failed to import, and why",
    blocked: "no collector, keys exist",
  },
  {
    name: "Tdarr FileJSONDB",
    detail: "per-file transcode state; the queue drains to zero by design",
    blocked: "getAll per file is expensive",
  },
  {
    name: "qBittorrent /torrents",
    detail: "rate, ratio, seeding state, inside the VPN namespace",
    blocked: "reachable only as torrent:8200",
  },
  {
    name: "home_server_tdarr_queue_files",
    detail: "the counts by verdict, which is what exists today",
    blocked: "ready",
  },
];
</script>

<template>
  <StubPage title="Library" :sources="sources" />
</template>
