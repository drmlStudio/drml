<script setup lang="ts">
defineProps<{
  items: Array<{
    title: string
    description: string
    command: string
  }>
>()
</script>

<template>
  <div class="capability-grid">
    <article v-for="item in items" :key="item.title" class="capability-card">
      <h3>{{ item.title }}</h3>
      <p>{{ item.description }}</p>
      <code>{{ item.command }}</code>
    </article>
  </div>
</template>

<style scoped>
.capability-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; margin: 40px auto; max-width: 960px; }
.capability-card { border: 1px solid var(--vp-c-divider); border-radius: 18px; padding: 24px; background: linear-gradient(145deg, rgba(56,189,248,.06), rgba(139,92,246,.035)); }
.capability-card h3 { margin-top: 0; }
.capability-card p { color: var(--vp-c-text-2); }
.capability-card code { color: #67e8f9; }
@media (max-width: 640px) { .capability-grid { grid-template-columns: 1fr; } }
</style>
