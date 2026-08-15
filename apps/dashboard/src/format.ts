// =============================================================================
// Formatting
// -----------------------------------------------------------------------------
// Every function here answers NaN with a dash rather than with 0. "No data" and
// "zero" are different findings, and a dashboard that renders the first as the
// second is lying in the direction of everything being fine.
//
// ASCII ONLY, including the output: bin/lint-repo.sh fails the whole repository
// on a single byte above 0x7F, and these strings end up in the DOM either way.
// So "-" for a dash, "->" for an arrow, "x" for a multiplication sign.
// =============================================================================

export const NO_DATA = "-";

const KIB = 1024;
const UNITS = ["B", "KB", "MB", "GB", "TB", "PB"];

/** Binary multiples, which is what every source here reports. */
export function bytes(n: number, digits = 1): string {
  if (!Number.isFinite(n)) return NO_DATA;
  if (n === 0) return "0 B";

  const sign = n < 0 ? "-" : "";
  let v = Math.abs(n);
  let unit = 0;
  while (v >= KIB && unit < UNITS.length - 1) {
    v /= KIB;
    unit += 1;
  }
  // Whole bytes have no fractional part worth showing, and a three-digit
  // value does not need one either: "412 GB" reads better than "412.3 GB".
  const places = unit === 0 ? 0 : v >= 100 ? 0 : digits;
  return `${sign}${v.toFixed(places)} ${UNITS[unit]}`;
}

export function rate(bytesPerSecond: number): string {
  if (!Number.isFinite(bytesPerSecond)) return NO_DATA;
  return `${bytes(bytesPerSecond)}/s`;
}

export function percent(ratio: number, digits = 0): string {
  if (!Number.isFinite(ratio)) return NO_DATA;
  return `${(ratio * 100).toFixed(digits)}%`;
}

export function number(n: number, digits = 0): string {
  if (!Number.isFinite(n)) return NO_DATA;
  return n.toFixed(digits);
}

export function celsius(n: number): string {
  if (!Number.isFinite(n)) return NO_DATA;
  return `${n.toFixed(0)}C`;
}

export function watts(n: number): string {
  if (!Number.isFinite(n)) return NO_DATA;
  return `${n.toFixed(0)} W`;
}

export function hertz(n: number): string {
  if (!Number.isFinite(n)) return NO_DATA;
  return `${(n / 1e6).toFixed(0)} MHz`;
}

/**
 * A duration, at the coarsest two units that still carry information:
 * "41d 06h", "6h 12m", "4m 30s", "12s". Uptime and age are read at a glance
 * and nobody wants seconds next to days.
 */
export function duration(seconds: number): string {
  if (!Number.isFinite(seconds)) return NO_DATA;

  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;

  if (d > 0) return `${d}d ${String(h).padStart(2, "0")}h`;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(sec).padStart(2, "0")}s`;
  return `${sec}s`;
}

/**
 * A single coarse unit: "41d", "6h", "23m", "12s". For anywhere a duration is
 * a glanceable aside rather than the subject - the header chip in particular,
 * where a ticking seconds field draws the eye to the least useful number on
 * the page.
 */
export function coarse(seconds: number): string {
  if (!Number.isFinite(seconds)) return NO_DATA;
  const s = Math.max(0, Math.floor(seconds));
  if (s >= 86400) return `${Math.floor(s / 86400)}d`;
  if (s >= 3600) return `${Math.floor(s / 3600)}h`;
  if (s >= 60) return `${Math.floor(s / 60)}m`;
  return `${s}s`;
}

/** Drive power-on time. Hours are what SMART reports and what a datasheet
 *  quotes, but nobody reads 41207 as "four and a half years". */
export function powerOnHours(hours: number): string {
  if (!Number.isFinite(hours)) return NO_DATA;
  if (hours < 8760) return `${Math.round(hours)} h powered`;
  return `${(hours / 8760).toFixed(1)}y powered`;
}

/** "6h ago", "just now", "never". Takes unix seconds. */
export function since(unixSeconds: number, now = Date.now() / 1000): string {
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return "never";
  const delta = now - unixSeconds;
  if (delta < 45) return "just now";
  return `${duration(delta)} ago`;
}

/** Same, from an ISO 8601 string - which is how status.json spells a time. */
export function sinceIso(iso: string | null | undefined, now = Date.now() / 1000): string {
  if (!iso) return "never";
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "never";
  return since(t / 1000, now);
}

export function isoToUnix(iso: string | null | undefined): number {
  if (!iso) return Number.NaN;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? Number.NaN : t / 1000;
}

/** Wall-clock "14:03", for an axis or an event row. Local time, because the
 *  host runs Europe/Brussels and so does whoever is reading this. */
export function clock(unixSeconds: number): string {
  if (!Number.isFinite(unixSeconds)) return NO_DATA;
  const d = new Date(unixSeconds * 1000);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** "15 Aug 14:03" - for anything that may be older than today. */
export function stamp(unixSeconds: number): string {
  if (!Number.isFinite(unixSeconds)) return NO_DATA;
  const d = new Date(unixSeconds * 1000);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${d.getDate()} ${months[d.getMonth()]} ${clock(unixSeconds)}`;
}

/**
 * A container name from a systemd unit, or the unit itself when it does not
 * end in .service. podman's PODMAN_SYSTEMD_UNIT label is the identity join
 * CLAUDE.md insists on - "never on a name derived from the container" - so
 * this only ever tidies it for display.
 */
export function unitName(unit: string | undefined): string {
  if (!unit) return NO_DATA;
  return unit.replace(/\.service$/, "");
}

/** ghcr.io/haveagitgat/tdarr:latest -> haveagitgat/tdarr:latest. The registry
 *  is the least interesting part of a reference and the widest column. */
export function shortImage(image: string | undefined): string {
  if (!image) return NO_DATA;
  const withoutDigest = image.replace(/@sha256:[0-9a-f]{64}$/, "");
  const parts = withoutDigest.split("/");
  if (parts.length > 1 && (parts[0].includes(".") || parts[0].includes(":"))) {
    return parts.slice(1).join("/");
  }
  return withoutDigest;
}
