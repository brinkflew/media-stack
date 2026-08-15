import { createRouter, createWebHistory } from "vue-router";

/**
 * Four routes, two of them built. `/` lands on System rather than Home because
 * Home is the stub: sending someone to a page that says "not built" would be a
 * strange front door.
 *
 * History mode, not hash: the container's Caddyfile does try_files {path}
 * /index.html, so a deep link and a reload both resolve.
 */
export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", redirect: "/system" },
    {
      path: "/system",
      name: "system",
      component: () => import("@/pages/SystemPage.vue"),
    },
    {
      path: "/services",
      name: "services",
      component: () => import("@/pages/ServicesPage.vue"),
    },
    {
      path: "/home",
      name: "home",
      component: () => import("@/pages/HomePage.vue"),
    },
    {
      path: "/library",
      name: "library",
      component: () => import("@/pages/LibraryPage.vue"),
    },
    { path: "/:pathMatch(.*)*", redirect: "/system" },
  ],
});
