#!/usr/bin/env bash
# ==============================================================================
# Prove a candidate runner image before anything runs model-authored code in it
# ------------------------------------------------------------------------------
# stacks/infra/conduct-runner.build tags :next. This is what decides whether
# :next becomes :latest, and it is the whole reason that indirection exists:
# apps/caddy/Dockerfile can be its own gate because xcaddy fails to compile
# against an incompatible Caddy, while `npm install -g @anthropic-ai/claude-code`
# and `apt-get install` both succeed against a release that does not work.
#
# So this asserts two different things, and the second is the one worth having:
#
#   TOOLING     every binary the gate shells out to actually answers, the three
#               cache mounts are really required and really writable, and
#               chromium LAUNCHES - not `--version`, a real headless browser
#               rendering a page under --cap-drop=ALL and --read-only. That
#               interaction is where this image breaks, not the parts.
#
#   CONTAINMENT the forbidden edges, BY IP from a container shaped exactly like
#               a phase runner, on a throwaway isolate=true network. The house
#               rule in docs/networking.md is that an edge is proven by address
#               and never by name resolution, and that a REFUSAL is not a
#               blocked edge - the packet arrived and only the port was shut.
#               This script keeps that distinction: 124 from `timeout` is the
#               pass, 1 is a different finding entirely.
#
# It runs from home-server-conduct-runner-build.service, between the build and
# the promotion. Run it by hand against a candidate with
#   CONDUCT_RUNNER_IMAGE=localhost/home-server/conduct-runner:next bin/conduct-runner-smoke.sh
#
# It does NOT measure cgroup peaks. Those belong to a real `make check-gate`
# run, which is step 11's; the numbers this repository has today came from a
# pre-flight and are recorded in host/systemd/app-agents.slice.
# ==============================================================================
set -euo pipefail

IMAGE="${CONDUCT_RUNNER_IMAGE:-localhost/home-server/conduct-runner:next}"
FLEET_ROOT="${CONDUCT_FLEET_ROOT:-/var/home-server/cache/conduct}"
NET="net-conduct-smoke"
WT="$FLEET_ROOT/worktrees/.smoke"

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
note() { printf '  note  %s\n' "$*"; }
say()  { printf '\n%s\n' "$*"; }

# The network is named under the net-conduct-* prefix on purpose: `conduct`
# reaps orphans by that prefix at startup, so a leak from a killed run is
# cleaned up by the same code that reaps a leaked phase network.
# shellcheck disable=SC2317  # reached through the EXIT trap, which shellcheck
# cannot follow. The repo's other traps are one-liners, which is why this is the
# first place the directive is needed.
cleanup() {
	podman rm -f conduct-smoke >/dev/null 2>&1 || true
	podman network rm -f "$NET" >/dev/null 2>&1 || true
	rm -rf "$WT"
}
trap cleanup EXIT INT TERM

# Every container this script starts carries io.home-server.ephemeral. Without
# it the 30-second collector would count them as unmapped containers and mint
# network series under a name that never repeats - see docs/observability.md.
# This script is the first real user of that label.
runner() {
	podman run --rm -i --name conduct-smoke \
		--label io.home-server.ephemeral \
		--network "$NET" \
		--security-opt no-new-privileges --cap-drop=ALL \
		--shm-size=1g --log-driver=none --no-healthcheck \
		--read-only --read-only-tmpfs --tmpfs /tmp:rw,exec,size=2g \
		--dns 1.1.1.1 --dns 1.0.0.1 \
		-v "$FLEET_ROOT/pw-browsers:/opt/pw-browsers:rw" \
		-v "$FLEET_ROOT/uv-cache:/opt/uv-cache:rw" \
		-v "$FLEET_ROOT/bun-cache:/opt/bun-cache:rw" \
		-v "$WT:$WT:rw" -w "$WT" \
		-v "$FLEET_ROOT/policy:/opt/conduct:ro" \
		"$IMAGE" "$@"
}

printf 'conduct-runner smoke: %s\n' "$IMAGE"

if ! podman image exists "$IMAGE"; then
	printf '  FAIL  no such image\n'
	exit 1
fi
printf '  image %s bytes, built %s\n' \
	"$(podman image inspect "$IMAGE" --format '{{.Size}}')" \
	"$(podman image inspect "$IMAGE" --format '{{.Created}}')"

mkdir -p "$WT" "$FLEET_ROOT/pw-browsers" "$FLEET_ROOT/uv-cache" "$FLEET_ROOT/bun-cache"
podman network create --opt isolate=true "$NET" >/dev/null

# ------------------------------------------------------------------------------
say "Tooling"
# ------------------------------------------------------------------------------
# Every one of these is on the critical path of upskald's `make check-gate`, and
# python3 is on it six times over: version-check is `python3 scripts/versioning.py`,
# lint runs check_prose.py, unit-test-api runs preflight_ports.py, unit-test-scripts
# is `python3 -m unittest`, and every recipe opens with an eval of worktree_env.py.
# node:24-trixie-slim ships none of python3, git or make, which is why they are
# asserted rather than assumed.
# shellcheck disable=SC2016  # $t is expanded by the shell INSIDE the container,
# not by this one - expanding it here would be the bug.
missing=$(runner sh -c '
	for t in node npm bun bunx uv uvx python3 git make jq gh claude; do
		command -v "$t" >/dev/null 2>&1 || printf "%s " "$t"
	done
	ldconfig -p | grep -q libmagic || printf "libmagic "
') || true
if [ -z "$missing" ]; then
	ok "node bun uv python3 git make jq gh claude, and libmagic, all present"
else
	bad "absent from the image: $missing"
fi

# api/pyproject.toml is requires-python >=3.13 and uv brings its own interpreter,
# but the repo-root scripts run on the SYSTEM python3 - so its version is the
# one that has to satisfy that floor, and Debian is what decides it.
if runner python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 13) else 1)'; then
	ok "system python3 is $(runner python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
else
	bad "system python3 is older than 3.13, which api/pyproject.toml requires"
fi

# `claude --version` is the assertion this whole :next/:latest dance exists for.
if v=$(runner claude --version 2>&1); then
	ok "claude answers: $v"
else
	bad "claude does not run: $v"
fi

# ------------------------------------------------------------------------------
say "The three cache mounts, which are required and fail obscurely"
# ------------------------------------------------------------------------------
# Measured: with /opt/bun-cache unmounted, `bun add` dies with "bun is unable to
# write files to tempdir: ReadOnlyFileSystem", naming neither the variable nor
# the path. One `bun add` covers the whole class, and it is also the cheapest
# proof that outbound HTTPS works at all from an isolate=true network - which is
# not obvious, and which every phase depends on.
if runner sh -c 'cd /tmp && bun init -y >/dev/null 2>&1; bun add left-pad >/dev/null 2>&1'; then
	ok "bun add resolved and installed a package (so BUN_INSTALL_CACHE_DIR is writable and egress works)"
else
	bad "bun add failed - check that $FLEET_ROOT/bun-cache is mounted at /opt/bun-cache"
fi

if runner sh -c 'cd /tmp && uv venv v >/dev/null 2>&1 && v/bin/python -c "print(1)" >/dev/null'; then
	ok "uv built a virtualenv and ran its interpreter"
else
	bad "uv failed - check that $FLEET_ROOT/uv-cache is mounted at /opt/uv-cache"
fi

# ------------------------------------------------------------------------------
say "Chromium, launched rather than versioned"
# ------------------------------------------------------------------------------
# Browser binaries are deliberately not baked into the image - see the Dockerfile
# - so this is also what fills the shared browser volume. It is the assertion
# that covers the interaction rather than the parts: --cap-drop=ALL, --read-only,
# a tmpfs /tmp that must be exec, and a 1g /dev/shm, all at once. Chromium's
# default 64 MB /dev/shm is where "flaky tab crash" comes from.
if runner bash -s <<'IN'; then
set -e
cd /tmp && mkdir -p pw && cd pw
bun init -y >/dev/null 2>&1 || true
bun add playwright@1 >/dev/null
bunx playwright install chromium >/dev/null
node -e '
  const { chromium } = require("playwright");
  chromium.launch().then(async b => {
    const p = await b.newPage();
    await p.setContent("<h1>runner-ok</h1>");
    const t = await p.$eval("h1", e => e.textContent);
    await b.close();
    if (t !== "runner-ok") { console.error("rendered", t); process.exit(1); }
    console.log(b.version());
  }).catch(e => { console.error(e.message); process.exit(1); });
'
IN
	ok "chromium installed, launched headless and rendered a page"
else
	bad "chromium did not launch under --cap-drop=ALL --read-only"
fi

# ------------------------------------------------------------------------------
say "Containment"
# ------------------------------------------------------------------------------
# A forbidden edge is proven BY IP from a throwaway container, never by name
# resolution: a container has one address per network it joins, a name proves
# only one of them, and the unit files look identical either way.
#
# THE EXIT CODE IS THE FINDING, NOT MERELY ITS SIGN. bash's /dev/tcp returns 1
# immediately on ECONNREFUSED - the packet arrived and the port was shut - and
# `timeout` returns 124 when the connection is silently dropped. Only 124 is a
# blocked edge. Reporting "nonzero" would call a refusal a success.
probe() {
	local label="$1" host="$2" port="$3" want="$4"
	local rc=0
	runner timeout 6 bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1 || rc=$?
	case "$want:$rc" in
		dropped:124)   ok "$label is dropped (rc 124)" ;;
		dropped:1)     bad "$label is REFUSED, not dropped - the packet arrived and only the port was shut, which is not a blocked edge" ;;
		dropped:*)     bad "$label returned rc $rc, which is neither 124 (dropped) nor 1 (refused) - the probe itself did not run, so this proves nothing either way" ;;
		open:0)        ok "$label is reachable (rc 0)" ;;
		open:*)        bad "$label returned rc $rc, expected 0" ;;
	esac
}

lan=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')

if podman ps --format '{{.Names}}' | grep -qx windmill-db; then
	dbip=$(podman inspect windmill-db --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
	probe "windmill-db at $dbip:5432" "$dbip" 5432 dropped
else
	note "windmill-db is not running, so the control plane edge cannot be probed"
fi

# THE STACK IS ALSO UNREACHABLE THE LONG WAY ROUND, and this was measured rather
# than assumed - the plan asserted the opposite. Reaching Caddy at the host's LAN
# address DNATs into net-ingress, so it is a bridge-to-bridge flow and
# isolate=true drops it. Verified against a plain bridge, where both of these
# connect. What is NOT blocked is the host itself: port 22 is REFUSED from here,
# not dropped, so the isolation is about where the packet ends up and not about
# the address it is aimed at.
if [ -n "$lan" ]; then
	probe "caddy via the host publish $lan:443" "$lan" 443 dropped
	probe "jellyfin via the host publish $lan:8096" "$lan" 8096 dropped
else
	note "the host's LAN address could not be derived, so the publish edges were not probed"
fi

# The negative that is not an edge at all: the runner must never be able to ask
# podman for anything. This is the constraint the whole three-tier design rests
# on - container_t -> unconfined_t : unix_stream_socket connectto is DENY under
# enforcing SELinux - and it is asserted here because a bind mount would defeat
# it silently.
if runner sh -c 'test ! -e /run/user/1000/podman/podman.sock && test ! -e /var/run/docker.sock'; then
	ok "no podman or docker socket is visible inside the runner"
else
	bad "a container socket is reachable from inside the runner"
fi

if runner sh -c 'touch /usr/local/bin/smoke 2>/dev/null && exit 1; exit 0'; then
	ok "the root filesystem rejects a write"
else
	bad "the root filesystem is writable - --read-only is not in force"
fi

# noexec on /tmp breaks uv's managed interpreters and node's temporary binaries,
# and the failure names neither. podman's own read-only tmpfs would do, but the
# invocation overrides /tmp to bound its size, and an override is a place to get
# this wrong.
if runner sh -c 'printf "#!/bin/sh\nexit 0\n" > /tmp/x && chmod +x /tmp/x && /tmp/x'; then
	ok "/tmp is writable and executable"
else
	bad "/tmp is not both writable and executable"
fi

# ------------------------------------------------------------------------------
say "The deny hook, which fails open when it is missing"
# ------------------------------------------------------------------------------
# THIS IS THE ONE PLACE THE HOOK IS TESTABLE WITHOUT A MODEL OR A CREDENTIAL, and
# that is why it is here rather than in a phase. It is a filter: JSON in, a
# decision out. So the assertion is three canned PreToolUse payloads and the
# exact permissionDecision each must produce.
#
# WHAT IT REALLY GUARDS IS THE FAIL-OPEN. Measured against Claude Code 2.1.238: a
# --settings hook whose command does not exist lets the tool call PROCEED. So
# "python3 moved in the base image", "the policy never got staged" and "the JSON
# is malformed" all produce a phase that runs with no guardrail and says nothing
# about it - and each of them fails this leg loudly instead.
#
# The policy is conduct's artifact rather than the image's, so it is staged here
# if the orchestrator is installed. A host without /var/agents has nothing to
# test and says so; a host WITH it and no policy is a real fault.
if [ -x /var/agents/bin/conduct ]; then
	/var/agents/bin/conduct policy >/dev/null 2>&1 || true
fi

hook_says() {
	local label="$1" payload="$2" want="$3" got
	got=$(printf '%s' "$payload" | runner python3 /opt/conduct/deny.py 2>/dev/null |
		python3 -c 'import json,sys
raw = sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"]["permissionDecision"] if raw else "none")' 2>/dev/null)
	if [ "$got" = "$want" ]; then
		ok "$label -> $got"
	else
		bad "$label -> ${got:-<nothing>}, wanted $want"
	fi
}

if [ ! -r "$FLEET_ROOT/policy/deny.py" ]; then
	note "no policy staged at $FLEET_ROOT/policy - install conduct, or run 'conduct policy'"
else
	hook_says "the PR gate's bypass string" \
		'{"tool_name":"Bash","tool_input":{"command":"PR_GATE_BYPASS=1 gh pr create"}}' deny
	hook_says "a write to .claude/settings.json" \
		'{"tool_name":"Write","tool_input":{"file_path":".claude/settings.json"}}' deny
	# NOT "allow". A PreToolUse allow BYPASSES the permission system, so the
	# correct answer for an ordinary command is silence, and a hook that answered
	# "allow" here would auto-approve everything the phase does.
	hook_says "an ordinary command" \
		'{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' none
	# The inverse of scripts/pr_quality_gate.py, deliberately: that one returns
	# no opinion on any exception because a hook must not take a human's shell
	# down. This one denies, because what it costs is one robot's pull request.
	hook_says "input that is not JSON at all" 'not json' deny

	if runner sh -c 'echo x > /opt/conduct/deny.py' >/dev/null 2>&1; then
		bad "/opt/conduct is WRITABLE - a phase can disarm its own guardrail"
	else
		ok "/opt/conduct is read-only"
	fi
	if runner sha256sum -c --quiet /opt/conduct/SHA256SUMS >/dev/null 2>&1; then
		ok "the staged policy matches its digests"
	else
		bad "the staged policy does not match SHA256SUMS - it is stale or truncated"
	fi
fi

# ------------------------------------------------------------------------------
if [ "$fails" -eq 0 ]; then
	printf '\nsmoke passed; %s may be promoted\n' "$IMAGE"
	exit 0
fi
printf '\nsmoke FAILED with %s finding(s); %s must NOT be promoted\n' "$fails" "$IMAGE"
exit 1
