# ==============================================================================
# Caddy with the Gandi DNS provider
# ------------------------------------------------------------------------------
# The official Caddy image ships no DNS provider modules, and certificates here
# are issued over DNS-01 against Gandi, so the binary has to be rebuilt with the
# provider compiled in. That is what xcaddy does.
#
# Note that caddy-dns/gandi expects a Gandi *Personal Access Token* as its
# bearer_token. The legacy `dns_gandi_api_key` that certbot used in SWAG is a
# different, now-deprecated credential and will not authenticate.
#
# BOTH STAGES ARE PINNED BY DIGEST, and the tags are left alongside only as a
# hint to a human about what they are. This is the only image in the stack that
# is built rather than pulled, so it was also the only one with no rollback:
# `caddy:2` moves, and the next rebuild would silently produce a different
# proxy. That matters most during the host migration, where the new machine
# rebuilds this from scratch and it is the sole path to every service - the
# worst possible moment to meet a Caddy nobody has run before.
#
# Updating is deliberate: change a digest, rebuild, verify, commit. Resolve the
# current ones with
#   docker manifest inspect caddy:2 --verbose | grep -m1 digest
#
# See: https://github.com/caddy-dns/gandi
#      https://caddyserver.com/docs/build#xcaddy
# ==============================================================================

FROM caddy:2-builder@sha256:198d47eaee306d4d0c38a9960c89ff2c959aa29ad51d3e2dafa3e93ac961782a AS builder

RUN xcaddy build --with github.com/caddy-dns/gandi

FROM caddy:2@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
