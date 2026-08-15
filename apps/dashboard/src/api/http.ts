// =============================================================================
// One fetch wrapper, and the reason it exists
// -----------------------------------------------------------------------------
// AN EXPIRED SESSION IS A 302, NOT A 401, and that is the single thing most
// likely to make this dashboard look broken.
//
// Caddy's `protected` snippet runs forward_auth against Tinyauth, which answers
// an unauthenticated request with 401 plus the login URL in X-Tinyauth-Location
// - and Caddy turns that into a redirect. `fetch` follows redirects by default,
// so an expired session does not reject and does not surface a status code: it
// RESOLVES, with res.ok true and an HTML sign-in page as the body. JSON.parse
// then throws somewhere far away, and every panel silently shows nothing.
//
// So every call goes through here, and two signals are treated as "signed out":
// a cross-origin redirect, and a non-JSON content type. The cure is a full page
// load, because a passkey prompt cannot be completed inside an XHR.
//
// THE RELOAD IS RATE-LIMITED, deliberately. If something OTHER than sign-on
// starts returning HTML - a 502 page from a restarting upstream, say - an
// unguarded reload-on-HTML is an infinite refresh loop that also hides the
// error. Past one reload per 30 seconds this surfaces as a state the UI can
// render instead.
// =============================================================================

const RELOAD_KEY = "home-server.reauth-at";
const RELOAD_MIN_INTERVAL_MS = 30_000;
const DEFAULT_TIMEOUT_MS = 12_000;

export class SignedOutError extends Error {
  constructor() {
    super("signed out");
    this.name = "SignedOutError";
  }
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly url: string,
    message: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

/** True when we bounced the browser at sign-on; the caller should stop. */
function reauthenticate(): boolean {
  let last = 0;
  try {
    last = Number(sessionStorage.getItem(RELOAD_KEY) ?? 0);
  } catch {
    // Private mode, or storage disabled. Fall through to "do not reload",
    // which degrades to showing the signed-out state rather than looping.
    return false;
  }

  if (Date.now() - last < RELOAD_MIN_INTERVAL_MS) return false;

  sessionStorage.setItem(RELOAD_KEY, String(Date.now()));
  window.location.reload();
  return true;
}

function looksLikeSignIn(res: Response): boolean {
  // A same-origin redirect is ordinary (Prometheus does a few of its own).
  // Only a hop to another host - auth.<domain> or id.<domain> - is sign-on.
  if (res.redirected && new URL(res.url).origin !== window.location.origin) return true;

  const type = res.headers.get("content-type") ?? "";
  return type.includes("text/html");
}

export interface FetchOptions {
  signal?: AbortSignal;
  timeoutMs?: number;
  method?: "GET" | "POST";
  body?: URLSearchParams;
}

export async function fetchJson<T>(url: string, options: FetchOptions = {}): Promise<T> {
  const timeout = AbortSignal.timeout(options.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  const signal = options.signal ? AbortSignal.any([options.signal, timeout]) : timeout;

  const res = await fetch(url, {
    signal,
    method: options.method ?? "GET",
    // The session cookie is what carries sign-on. There is no token anywhere
    // in this application by design - see apps/dashboard/README.md.
    credentials: "same-origin",
    redirect: "follow",
    headers: {
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
    },
    ...(options.body ? { body: options.body } : {}),
  });

  if (looksLikeSignIn(res)) {
    reauthenticate();
    throw new SignedOutError();
  }

  if (!res.ok) {
    // Prometheus puts a usable reason in a JSON body even on 4xx, so try it
    // before falling back to the status line.
    let detail = res.statusText;
    try {
      const body = (await res.json()) as { error?: string };
      if (body.error) detail = body.error;
    } catch {
      // Not JSON. The status line is all there is.
    }
    throw new HttpError(res.status, url, detail);
  }

  return (await res.json()) as T;
}
