// =============================================================================
// Poster URLs, built in exactly one place
// -----------------------------------------------------------------------------
// Images come same-origin through Caddy's /api/images/* handle, which reverse
// proxies Jellyfin. Its image endpoints answer 200 unauthenticated while every
// other path answers 401, so this carries no credential and a mis-scoped request
// fails closed into Jellyfin's own refusal.
//
// ONE PLACE builds the URL so that the prefix and the parameter order cannot
// drift, and so a 403 in the network tab is diagnosable from a single grep.
//
// THE SET OF HEIGHTS IS FIXED, AND THAT IS NOT FUSSINESS. Every distinct
// maxHeight makes Jellyfin perform a fresh resize and store a fresh cache entry,
// so asking for 237px in one slot and 240px in another doubles that work for a
// difference nobody can see. Slots snap to the smallest member at or above twice
// their rendered height, which is what keeps them sharp on a 2x display.
// =============================================================================

export const POSTER_HEIGHTS = [80, 240, 480] as const;

/** The smallest allowed height that covers a slot at 2x. */
export function posterHeight(cssHeight: number): number {
  const wanted = cssHeight * 2;
  for (const h of POSTER_HEIGHTS) {
    if (h >= wanted) return h;
  }
  return POSTER_HEIGHTS[POSTER_HEIGHTS.length - 1];
}

/**
 * @param path a bare Jellyfin image path, e.g. "Items/<id>/Images/Primary"
 * @param tag  the image's content hash, or null. Its PRESENCE is what makes the
 *             response cacheable: the proxy sets a long immutable cache only for
 *             a tagged request, because an untagged one is whatever the current
 *             image happens to be and caching that would pin a stale poster.
 */
export function posterUrl(path: string, tag: string | null, maxHeight: number): string {
  const params = new URLSearchParams();
  if (tag) params.set("tag", tag);
  params.set("maxHeight", String(maxHeight));
  return `/api/images/${path}?${params.toString()}`;
}
