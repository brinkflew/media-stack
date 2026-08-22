// =============================================================================
// home_server_container_health, and the one value that is not a number
// -----------------------------------------------------------------------------
// Lifted out of ServicesPage.vue, unchanged, because the Home page's service
// strip needs the identical mapping and this is the subtlest rule in the whole
// application to get wrong quietly.
//
// THE METRIC IS ABSENT, NOT ZERO, for a container that defines no health check.
// duckdns and unpackerr serve no HTTP and have none, so `health.get(name)`
// returns undefined - and undefined must render GREY, never green. Zero means
// "checked and healthy"; absent means "nobody is checking". A page that treats
// them alike reports two containers as verified healthy on the strength of no
// evidence at all, which is exactly the shape of failure this repository is
// written around, and it is invisible because grey and green both look fine.
//
// It is also what lets one alert rule cover every container without naming any:
// `home_server_container_health == 2` matches nothing for a container that
// emits no series.
// =============================================================================

import type { CheckStatus, Tone } from "@/types";

export interface ContainerHealth {
  tone: Tone;
  /** Prose for the row, and deliberately not parsed anywhere. */
  state: string;
}

/**
 * @param running whether the container is up at all
 * @param health  0 healthy, 1 starting, 2 unhealthy, undefined = no check defined
 */
export function containerTone(running: boolean, health: number | undefined): ContainerHealth {
  if (!running) return { tone: "fail", state: "stopped" };
  if (health === undefined) return { tone: "off", state: "running, unchecked" };
  if (health === 0) return { tone: "ok", state: "healthy" };
  if (health === 1) return { tone: "warn", state: "starting" };
  return { tone: "fail", state: "unhealthy" };
}

/**
 * A check's status as a tone. ONE FUNCTION, because two call sites guessing is
 * how the System page came to draw a `note` amber in the strip at the top and
 * grey in the list below it - the strip bound `:class="c.status"` and only
 * `.fail` had an override, so `note` fell through to the warn treatment and
 * nothing said so.
 *
 * `note` IS GREY, not amber. bin/verify-host.sh emits it for a check that could
 * not run, and the whole argument above containerTone applies unchanged: an
 * unmeasured thing must not borrow the colour of a measured one, in either
 * direction.
 */
export function checkTone(status: CheckStatus): Tone {
  switch (status) {
    case "fail":
      return "fail";
    case "warn":
      return "warn";
    case "pass":
      return "ok";
    default:
      return "off";
  }
}
