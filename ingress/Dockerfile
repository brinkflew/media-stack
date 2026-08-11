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
# See: https://github.com/caddy-dns/gandi
#      https://caddyserver.com/docs/build#xcaddy
# ==============================================================================

FROM caddy:2-builder AS builder

RUN xcaddy build --with github.com/caddy-dns/gandi

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
