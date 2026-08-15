// =============================================================================
// Vite configuration
// -----------------------------------------------------------------------------
// Two dev modes, because the two things worth developing against are different:
//
//   npm run dev                     fixtures. Deterministic, offline, and the
//                                   only way to exercise a degraded host - a
//                                   failing check, a stale collector, a disk
//                                   at 91 percent - without breaking one.
//
//   VITE_PROM=http://localhost:9090 npm run dev
//                                   the real Prometheus, over an ssh tunnel to
//                                   its bridge address. Prometheus publishes no
//                                   host port, so see apps/dashboard/README.md
//                                   for the two commands that open one.
//
// In production none of this exists: Caddy serves the bundle and proxies
// /api/prom and /api/alerts under the same origin, which is what keeps the
// browser from ever holding a credential.
// =============================================================================

import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import { fixtureServer } from "./fixtures/server";

export default defineConfig(({ mode }) => {
  const upstream = process.env.VITE_PROM;

  return {
    plugins: [vue(), ...(upstream ? [] : [fixtureServer()])],

    resolve: {
      alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) },
    },

    define: {
      // Stamped into the bundle so the footer can name what is running.
      // Not a version number: this is built from a checkout, and the
      // commit is what identifies it.
      __BUILD_MODE__: JSON.stringify(mode),
    },

    server: {
      port: 5173,
      strictPort: true,
      proxy: upstream
        ? {
            "/api/prom": { target: upstream, changeOrigin: true, rewrite: (p) => p.replace(/^\/api\/prom/, "") },
          }
        : undefined,
    },

    build: {
      outDir: "dist",
      assetsDir: "assets",
      // The whole point of vendoring the fonts is to stop the page
      // fetching anything at run time. Inlining small assets keeps that
      // true for the icons too.
      assetsInlineLimit: 4096,
      target: "es2022",
      sourcemap: false,
      reportCompressedSize: false,
    },
  };
});
