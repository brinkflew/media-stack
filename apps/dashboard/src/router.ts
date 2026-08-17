import { createRouter, createWebHistory } from "vue-router";

/**
 * Four routes, all four built.
 *
 * `/` lands on Home now. It used to land on System, because Home was the stub and
 * sending someone to a page that says "not built" would have been a strange front
 * door. Home is the first entry in the nav and the page that answers "is anything
 * happening"; System is one click away, and the verdict chip in the nav is visible
 * from every page anyway.
 *
 * History mode, not hash: the container's Caddyfile does try_files {path}
 * /index.html, so a deep link and a reload both resolve.
 */
export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", redirect: "/home" },
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
    { path: "/:pathMatch(.*)*", redirect: "/home" },
  ],
});
