# ==============================================================================
# The dashboard image: build the SPA, serve the bundle, reach nothing
# ------------------------------------------------------------------------------
# Two stages. The first needs the network and a toolchain; the second is a
# static file server with neither. Nothing from the builder survives except
# dist/, so node and the 60-odd build dependencies are not in the running image.
#
# REGISTRIES ARE FULLY QUALIFIED. Podman will not guess one - an unqualified
# `FROM node:24-alpine` dies under systemd with "short-name resolution enforced
# but cannot prompt without a TTY", which reads like a network fault.
#
# TAGS, NOT DIGESTS, for the reason stacks/README.md gives: the pinning was
# abandoned because nothing maintained it, and a pin with no update path is
# worse than a tag. home-server-dashboard-build.timer rebuilds this weekly and
# the .build unit carries Pull=newer, so both bases actually move.
#
# Image: docker.io/library/node, docker.io/library/caddy
# ==============================================================================

FROM docker.io/library/node:24-alpine AS builder

WORKDIR /build

# The lockfile is copied on its own first so that a source-only change reuses
# the cached install layer. `npm ci` rather than `npm install`: it installs
# exactly what package-lock.json says and fails if the two have drifted, which
# is the only reason to track a lockfile at all.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY tsconfig.json tsconfig.app.json tsconfig.node.json vite.config.ts env.d.ts index.html ./
COPY fixtures/ ./fixtures/
COPY src/ ./src/

# vue-tsc runs first (it is `npm run build`), so a type error fails the image
# build rather than shipping. There is no test suite here; this is the check.
RUN npm run build


FROM docker.io/library/caddy:2-alpine

# Not the custom home-server/caddy image: that one exists only to carry the
# caddy-dns/gandi module for DNS-01, and nothing here terminates TLS. This is
# stock Caddy serving files on plain HTTP inside its own network segment.
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /build/dist /srv/dist

# /srv/data is where the host's copy of status.json is bind-mounted read-only.
# Created here so the file server has a directory to answer from even before
# bin/verify-host.sh has ever run - the UI reports an absent file as "not
# measured yet", which is a different thing from a 404 against a missing root.
RUN mkdir -p /srv/data

EXPOSE 8080
