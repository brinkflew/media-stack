<script setup lang="ts">
import StubPage from "@/components/StubPage.vue";

/**
 * Everything this page needs is an application API that nothing currently
 * collects. `home_server_jellyfin_sessions{playback_method}` exists and gives
 * a COUNT, but not who is watching what - and a "now playing" card with a
 * number and no title is not the design.
 */
const sources = [
  {
    name: "Jellyfin /Sessions",
    detail: "now playing: title, user, position, whether it is direct-playing or transcoding",
    blocked: "no collector, needs an image proxy",
  },
  {
    name: "Jellyseerr /request",
    detail: "the pending request queue, which is the one thing here somebody else waits on",
    blocked: "no API key in .env yet",
  },
  {
    name: "Jellyfin /Items/Latest",
    detail: "recently added, as the poster grid",
    blocked: "posters are 30-60 images per load",
  },
  {
    name: "home_server_container_health",
    detail: "the service strip along the bottom, which is the only part already available",
    blocked: "ready",
  },
];
</script>

<template>
  <StubPage title="Home" :sources="sources" />
</template>
