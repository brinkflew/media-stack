<script setup lang="ts">
/**
 * A page that is routed but not built.
 *
 * It exists rather than being omitted because the shell is what this first cut
 * is meant to prove, and four tabs where two lead nowhere would prove less. It
 * says what it will read and what has to exist first - which is a different
 * thing from an empty page, and a very different thing from a page of panels
 * with no data in them, which is what "coming soon" usually looks like.
 */
defineProps<{
  title: string;
  /** What this page will show, once it can. */
  sources: { name: string; detail: string; blocked: string }[];
}>();
</script>

<template>
  <div class="stub">
    <h1 class="heading">{{ title }}</h1>
    <p class="lede">Not built. This is the second cut; the shell, System and Services are the first.</p>

    <ul class="sources">
      <li v-for="s in sources" :key="s.name" class="source">
        <span class="name mono">{{ s.name }}</span>
        <span class="detail">{{ s.detail }}</span>
        <span class="blocked mono">{{ s.blocked }}</span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.stub {
  padding: 40px var(--pad-page);
  max-width: 820px;
}

.heading {
  font: var(--t-ui-lg);
  font-size: 18px;
  color: var(--fg);
}

.lede {
  margin-top: 8px;
  font: var(--t-ui);
  color: var(--fg-4);
}

.sources {
  margin-top: 26px;
  border-top: 1px solid var(--line);
}

.source {
  display: grid;
  grid-template-columns: 190px 1fr 210px;
  gap: 16px;
  align-items: baseline;
  padding: 11px 0;
  border-bottom: 1px solid var(--line-faint);
}

.name {
  font: var(--t-mono-md);
  color: var(--fg-2);
}

.detail {
  font: var(--t-ui);
  color: var(--fg-4);
}

.blocked {
  font: var(--t-mono-sm);
  color: var(--fg-dim);
  text-align: right;
}
</style>
