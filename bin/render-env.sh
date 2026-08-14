#!/usr/bin/env bash
# ==============================================================================
# Render .env from the encrypted secrets file
# ------------------------------------------------------------------------------
# .env is GENERATED. Edit secrets/env.sops.env (with `sops secrets/env.sops.env`,
# which decrypts into your editor and re-encrypts on save), commit, pull, then
# run this. Editing .env directly works right up until the next render silently
# discards it.
#
# Run this before restarting any unit that needs a value which changed. The
# quadlets read .env from disk through EnvironmentFile=; they have no idea the
# encrypted original exists.
#
# Decryption needs the age private key at ~/.config/sops/age/keys.txt - sops'
# default lookup path. See .sops.yaml for which keys can decrypt.
# ==============================================================================

set -euo pipefail

# sops and age are installed per-user rather than system-wide, because /usr/local
# needs a sudo password here and a static binary in ~/.local/bin does not. That
# directory is not on a non-interactive ssh PATH, so put it there explicitly.
export PATH="$HOME/.local/bin:$PATH"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/secrets/env.sops.env"
dst="$root/.env"

command -v sops >/dev/null || { echo "render-env: sops not found on PATH" >&2; exit 1; }
[ -f "$src" ] || { echo "render-env: $src does not exist" >&2; exit 1; }

# Decrypt to a temporary file first. A failed decrypt part-way through a direct
# redirect would leave a truncated .env behind, and every ${VAR:?err} in the
# compose file would then fail at once - with the real cause already overwritten.
tmp="$(mktemp "$root/.env.render.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

sops --decrypt --input-type dotenv --output-type dotenv "$src" > "$tmp"

# A successful decrypt of an empty or malformed file is still a broken .env.
grep -q '^DOMAIN=' "$tmp" || { echo "render-env: decrypted output looks wrong (no DOMAIN)" >&2; exit 1; }

chmod 600 "$tmp"
mv "$tmp" "$dst"
trap - EXIT

echo "render-env: wrote $dst ($(grep -c '=' "$dst") variables)"
