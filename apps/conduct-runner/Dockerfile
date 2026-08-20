# ==============================================================================
# The phase runner: everything an agent writes, and nothing it can reach
# ------------------------------------------------------------------------------
# The third image built here rather than pulled, and the only one that is not a
# service. Nothing starts it at boot: `conduct` runs it as `podman run --rm` per
# phase, under a transient systemd scope in app-agents.slice, with --cap-drop=ALL,
# --read-only and a per-worktree network. See docs/agents.md.
#
# THE BUILD IS NOT ITS OWN SAFETY NET HERE, unlike apps/caddy/Dockerfile. xcaddy
# fails to compile against an incompatible Caddy, which is what makes caddy.build
# a real gate. `npm install -g @anthropic-ai/claude-code` succeeds against a
# broken release, and so does apt. So this image is tagged `:next`, and
# bin/conduct-runner-smoke.sh is what promotes it to `:latest` - see
# stacks/infra/conduct-runner.build.
#
# WHAT THE BASE IMAGE DOES NOT SHIP, read out of nodejs/docker-node's own
# Dockerfile rather than assumed: node:24-trixie-slim installs ca-certificates,
# curl, wget, gnupg, dirmngr, xz-utils and libatomic1, AND NOTHING ELSE. No
# python3, no git, no make. Six of upskald's eight `make check-gate` targets
# shell out to python3 - version-check is `python3 scripts/versioning.py`, lint
# runs check_prose.py, unit-test-api runs preflight_ports.py, unit-test-scripts
# is `python3 -m unittest`, and every recipe opens with
# `eval "$(python3 scripts/worktree_env.py)"` - so the obvious base image fails
# the gate at its first line. Every import in those scripts is stdlib, verified,
# which is why one apt package settles it and there is no pip layer here.
#
# TRIXIE RENAMED libmagic1 TO libmagic1t64, in the 64-bit time_t transition.
# api/pyproject.toml depends on python-magic and pytest imports the app, so the
# library is load-bearing; `apt-get install libmagic1` fails with "Unable to
# locate package", which is at least loud.
#
# Image: docker.io/library/node, ghcr.io/astral-sh/uv, docker.io/oven/bun
# See:   stacks/infra/conduct-runner.build, bin/conduct-runner-smoke.sh
# ==============================================================================

FROM docker.io/library/node:24-trixie-slim

# ONE APT LAYER, and the registry is spelled out above for the reason
# apps/caddy/Dockerfile documents: podman will not guess Docker Hub, and a
# systemd build has no TTY to prompt at.
#
# `gh` is Debian's, at 2.46 - old, and enough for `gh pr create --draft`. An apt
# package that Pull=newer refreshes beats a `curl | tar` with no checksum. There
# is deliberately NO docker CLI: with none on PATH every lookup in upskald's
# scripts/local_stacks.py reads as "unavailable" rather than as "wrong", which
# is the failure mode that check exists to avoid.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git make jq gh python3 libmagic1t64 \
 && rm -rf /var/lib/apt/lists/*

# uv and bun come from their own images rather than a shell installer, which is
# upstream's documented mechanism for both and needs no network at RUN time.
#
# `uv:0.12` IS A FLOATING PATCH TAG AND NOTHING ADVANCES THE MINOR BUT A PERSON.
# uv publishes no major tag at all - it is 0.x, and there is no bare `0` - so the
# choice was `latest`, which rolls across minors, or a minor. Same posture as
# stacks/README.md takes on windmill:1.792 and for the same reason: the gate's
# reproducibility rests on `uv sync`'s resolution semantics, and a minor landing
# unattended at 21:00 on a Saturday is how a green pipeline goes red for a reason
# nobody changed. bun publishes a rolling `1`, so bun gets it.
COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /uvx /usr/local/bin/
COPY --from=docker.io/oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun
RUN ln -sf /usr/local/bin/bun /usr/local/bin/bunx

# The line the smoke test exists for.
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# BROWSER LIBRARIES, NOT BROWSER BINARIES. @playwright/test is pinned ^1.60.0 in
# upskald's e2e/package.json, so a worktree can resolve a newer minor than this
# image was built against and Playwright then hunts a browser revision that is
# not there. Libraries move on a scale of years; revisions move monthly. So the
# system libraries are baked and the binary is not: PLAYWRIGHT_BROWSERS_PATH
# points at a mount the invocation supplies, filled at run time by the
# `bunx playwright install chromium` that upskald's `make install-e2e` already
# runs.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
RUN npx --yes playwright@1 install-deps chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# --read-only PLUS THE DEFAULT HOME=/root BREAKS EVERY TOOL THAT CACHES IN $HOME,
# and the error names a path nobody chose. claude writes ~/.claude, uv writes
# ~/.cache/uv, bun writes ~/.bun/install/cache. Fixed here rather than in the
# invocation because this is where it cannot be forgotten.
#
# HOME IS TMPFS AND EPHEMERAL ON PURPOSE. The Claude credential arrives as a
# podman secret in the environment, never as ~/.claude/.credentials.json, so a
# HOME that dies with the phase is containment rather than a cost - there is no
# state for one phase to leave behind for the next to find.
#
# The three caches that SHOULD survive a phase get explicit /opt paths, so the
# invocation mounts a directory rather than reaching into a home directory that
# moves. They are created here because a read-only rootfs cannot have a mount
# point created under it at run time.
#
# EVERY ONE OF THEM IS THEN A REQUIRED MOUNT, and the failure if one is missing
# names neither the variable nor the path. Measured: with /opt/bun-cache left
# unmounted, `bun add` dies with
#     error: bun is unable to write files to tempdir: ReadOnlyFileSystem
# which reads as a broken image rather than as a missing -v. bin/conduct-runner-smoke.sh
# runs `bun add` for exactly this reason - it is the cheapest assertion in the
# script and it covers the whole class.
ENV HOME=/tmp/home \
    UV_CACHE_DIR=/opt/uv-cache \
    BUN_INSTALL_CACHE_DIR=/opt/bun-cache \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN mkdir -p /opt/pw-browsers /opt/uv-cache /opt/bun-cache

# $HOME is on the tmpfs the invocation mounts at /tmp, so it does not exist until
# the container starts. Two lines of shell rather than making every caller
# remember, and `exec` so the phase command keeps pid 1 and its signals.
#
# It REPLACES node's own docker-entrypoint.sh deliberately: that one rewrites
# argv when the first word looks like a node flag, which is a surprise nobody
# wants standing between conduct and `make check-gate`.
RUN printf '%s\n' '#!/bin/sh' 'mkdir -p "$HOME"' 'exec "$@"' > /usr/local/bin/runner-init \
 && chmod 0755 /usr/local/bin/runner-init

# No git identity and no safe.directory here: identity belongs to the phase that
# commits, and the worktree is owned by core, which IS uid 0 inside a rootless
# container, so git sees a repository owned by itself and needs no exemption.
ENTRYPOINT ["/usr/local/bin/runner-init"]
CMD ["bash"]
