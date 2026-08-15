<script setup lang="ts">
import NavBar from "@/components/NavBar.vue";
import StalenessBanner from "@/components/StalenessBanner.vue";
import { useHostStore } from "@/stores/host";

// Instantiated here rather than per page, so the polls are shared and a route
// change does not restart them.
useHostStore();
</script>

<template>
  <div class="shell">
    <NavBar />
    <StalenessBanner />

    <main class="page">
      <RouterView v-slot="{ Component }">
        <component :is="Component" />
      </RouterView>
    </main>
  </div>
</template>

<style scoped>
.shell {
  display: flex;
  flex-direction: column;
  min-height: 100%;
}

.page {
  flex: 1;
  min-width: 0;
}
</style>
