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
# BOTH STAGES TRACK THE MAJOR TAG, not a digest. They were digest-pinned, which
# made a rebuild reproducible - and also meant a rebuild could never pick
# anything up, so this image would have been the one thing in the stack that
# never updated at all. `caddy:2` follows Caddy 2.x and stops before a 3.0.
#
# The rebuild is not automatic either way: a .build unit only runs when the
# image is absent, and podman auto-update's `local` policy notices a new image
# but does not produce one. media-stack-caddy-build.timer is what actually
# rebuilds, weekly; auto-update then restarts the proxy.
#
# THE BUILD IS THE SAFETY NET HERE, and it is a real one. xcaddy has to compile
# caddy-dns/gandi against the new Caddy, so an incompatible release fails at
# BUILD time - while the running container keeps serving, because the timer
# only produces an image and never restarts anything. This is the only update
# in the stack that can fail without taking its service down.
#
# What is given up: a rebuild on a fresh host produces whatever caddy:2 is that
# day, and it is the sole path to every service on a machine with no console.
# Check `journalctl --user -u caddy` for ACME errors after any Caddy update -
# the healthcheck answers on the admin API whether or not certificates work.
#
# THE REGISTRY IS SPELLED OUT because Podman, unlike Docker, does not assume
# Docker Hub for an unqualified name. It consults the short-name aliases and
# otherwise prompts - and a systemd unit has no terminal to prompt at, so the
# build dies with
#   Error: creating build container: short-name resolution enforced but cannot
#   prompt without a TTY
# which says nothing about registries. Caddy is the only image here that is
# built rather than pulled, so it is the only place this can bite.
#
# See: https://github.com/caddy-dns/gandi
#      https://caddyserver.com/docs/build#xcaddy
# ==============================================================================

FROM docker.io/library/caddy:2-builder AS builder

RUN xcaddy build --with github.com/caddy-dns/gandi

FROM docker.io/library/caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
