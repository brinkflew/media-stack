// =============================================================================
// Deterministic fake posters
// -----------------------------------------------------------------------------
// Real posters come from Caddy proxying Jellyfin, which does not exist in dev. A
// 404 for everything would hide the poster layout entirely, which is the opposite
// of what a fixture is for - so these are drawn instead.
//
// THE REQUESTED maxHeight IS PRINTED IN THE CORNER. A slot asking for the wrong
// size is otherwise invisible on screen, and there are only three legal values
// (see src/images.ts) precisely because each one costs Jellyfin a resize.
//
// MISSING_POSTERS is what exercises the fallback tile, which is the NORMAL state
// in two of the four slots - a pending request has no Jellyfin item at all.
// =============================================================================

/** Paths the fixture server answers 404 for, so the fallback is on screen. */
export const MISSING_POSTERS = [
  "Items/ffff0000000000000000000000000001/Images/Primary",
  "Items/ffff0000000000000000000000000002/Images/Primary",
];

/** Stable per path, so a reload does not reshuffle the colours. */
function hue(path: string): number {
  let h = 0;
  for (let i = 0; i < path.length; i += 1) h = (h * 31 + path.charCodeAt(i)) % 360;
  return h;
}

export function posterSvg(path: string, maxHeight: number): string {
  const w = 200;
  const h = 300;
  const id = path.split("/")[1]?.slice(0, 6) ?? "?";
  const bg = `oklch(0.32 0.04 ${hue(path)})`;
  const fg = `oklch(0.72 0.06 ${hue(path)})`;
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">`,
    `<rect width="${w}" height="${h}" fill="${bg}"/>`,
    `<rect x="0.5" y="0.5" width="${w - 1}" height="${h - 1}" fill="none" stroke="${fg}" stroke-opacity="0.4"/>`,
    `<text x="${w / 2}" y="${h / 2}" fill="${fg}" font-family="monospace" font-size="26"`,
    ` text-anchor="middle" dominant-baseline="middle">${id}</text>`,
    `<text x="${w - 8}" y="${h - 10}" fill="${fg}" fill-opacity="0.75" font-family="monospace"`,
    ` font-size="15" text-anchor="end">${maxHeight}</text>`,
    `</svg>`,
  ].join("");
}
