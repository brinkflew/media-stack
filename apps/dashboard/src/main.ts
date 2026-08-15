import { createApp } from "vue";
import { createPinia } from "pinia";

// Vendored, not fetched. The design document links Google Fonts; a page behind
// single sign-on that reaches out to a third party on every load is exactly
// what apps/jellyfin/custom.css was rewritten to stop doing.
//
// Only the weights the design actually uses, and only latin. The full family
// is fourteen files per face.
import "@fontsource/geist-sans/400.css";
import "@fontsource/geist-sans/500.css";
import "@fontsource/geist-sans/600.css";
import "@fontsource/azeret-mono/400.css";
import "@fontsource/azeret-mono/500.css";
import "@fontsource/azeret-mono/600.css";

import "@/styles/tokens.css";
import "@/styles/base.css";

import App from "@/App.vue";
import { router } from "@/router";

createApp(App).use(createPinia()).use(router).mount("#app");
