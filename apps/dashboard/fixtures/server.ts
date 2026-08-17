// =============================================================================
// The dev-only fixture server
// -----------------------------------------------------------------------------
// A Vite plugin that answers exactly what Caddy answers in production -
// /data/*.json, /api/prom/*, /api/alerts/* and /api/images/* - so the
// application code has no idea it is not talking to the real thing and there
// is no `if (dev)` anywhere in src/.
//
// It is dropped entirely when VITE_PROM is set, and it is never part of a
// build: nothing under src/ imports it.
// =============================================================================

import type { Plugin } from "vite";
import { alerts, statusDocument } from "./model";
import { activityDocument, libraryDocument } from "./media";
import { MISSING_POSTERS, posterSvg } from "./images";
import { instant, range, uncovered } from "./prometheus";

function send(res: { setHeader: (k: string, v: string) => void; end: (b: string) => void }, body: unknown): void {
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

export function fixtureServer(): Plugin {
  return {
    name: "home-server-fixtures",

    configureServer(server) {
      // Loud on startup rather than silent at request time. A query added to
      // src/queries.ts and not taught to the fixtures would otherwise render
      // an empty panel that looks like a host with nothing to report.
      const missing = uncovered();
      if (missing.length) {
        server.config.logger.warn(
          `[fixtures] ${missing.length} query(s) in src/queries.ts have no fixture:\n  ${missing.join("\n  ")}`,
        );
      }

      server.middlewares.use((req, res, next) => {
        const url = new URL(req.url ?? "/", "http://localhost");
        const path = url.pathname;

        if (path === "/data/status.json") {
          send(res, statusDocument());
          return;
        }

        if (path === "/data/activity.json") {
          send(res, activityDocument());
          return;
        }

        if (path === "/data/library.json") {
          send(res, libraryDocument());
          return;
        }

        // The poster proxy. Answering 404 for everything would hide the poster
        // layout entirely, so these are drawn - except for the handful in
        // MISSING_POSTERS, which exist to put the fallback tile on screen beside
        // real ones. That fallback is the NORMAL state for a pending request.
        if (path.startsWith("/api/images/")) {
          const inner = path.slice("/api/images/".length);
          if (MISSING_POSTERS.includes(inner)) {
            res.statusCode = 404;
            res.end("no such image");
            return;
          }
          res.setHeader("Content-Type", "image/svg+xml");
          res.setHeader("Cache-Control", "no-store");
          res.end(posterSvg(inner, Number(url.searchParams.get("maxHeight")) || 0));
          return;
        }

        if (path === "/api/alerts/api/v2/alerts") {
          send(res, alerts());
          return;
        }

        if (path === "/api/prom/api/v1/query") {
          const query = url.searchParams.get("query") ?? "";
          send(res, instant(query, Math.floor(Date.now() / 1000)));
          return;
        }

        if (path === "/api/prom/api/v1/query_range") {
          const query = url.searchParams.get("query") ?? "";
          const start = Number(url.searchParams.get("start"));
          const end = Number(url.searchParams.get("end"));
          const step = Number(url.searchParams.get("step"));
          send(res, range(query, start, end, step));
          return;
        }

        next();
      });
    },
  };
}
