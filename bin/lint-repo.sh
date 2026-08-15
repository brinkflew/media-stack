#!/usr/bin/env bash
# ==============================================================================
# The checks this repository can run on itself
# ------------------------------------------------------------------------------
# RUNS ANYWHERE, on a checkout. There is no application code here - no build, no
# test suite - so this is not a test runner. It asserts the few conventions that
# are otherwise enforced by nobody and drift silently.
#
# 1. EVERY TRACKED TEXT FILE IS ASCII. Typographic characters - em dashes, curly
#    quotes, box drawing, arrows - arrive by copy-paste and from anything that
#    generates prose, and they are invisible in review. 402 of them had
#    accumulated by 2026-08-14. They are worse than ugly in the shell scripts,
#    where they end up in a printf that a terminal may not render.
#
# 2. EVERY SCRIPT IN bin/ IS EXECUTABLE. A quadlet ExecStartPre= pointing at a
#    non-executable file fails at container start, which is a long way from the
#    commit that caused it.
#
# 3. THE SHELL SCRIPTS PASS SHELLCHECK, when shellcheck is installed. Skipped
#    rather than failed when it is not, so this stays runnable on the server.
#
# Usage:  bin/lint-repo.sh
# ==============================================================================

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fails=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  \033[2mSKIP\033[0m  %s\n' "$*"; }

# ------------------------------------------------------------------------------
say "ASCII"
# ------------------------------------------------------------------------------
# -I skips binary files, which is what stops this tripping over a future image.
# The pattern is any byte above 0x7F; grep -P is what makes that expressible.
offenders=$(git ls-files -z | xargs -0 grep -IPln '[^\x00-\x7F]' 2>/dev/null)
if [ -z "$offenders" ]; then
	ok "every tracked text file is ASCII"
else
	while IFS= read -r f; do
		n=$(grep -IPc '[^\x00-\x7F]' "$f" 2>/dev/null)
		bad "$f has non-ASCII on $n line(s)"
	done <<<"$offenders"
	printf '\n  The offending lines:\n'
	git ls-files -z | xargs -0 grep -IPn '[^\x00-\x7F]' 2>/dev/null | head -20 | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
say "Executable bits"
# ------------------------------------------------------------------------------
noexec=""
while IFS= read -r f; do
	[ -x "$f" ] || noexec="$noexec $f"
done < <(git ls-files 'bin/*.sh' 'bin/*.py' 'apps/*/scripts/*' 'host/greenboot/*.sh')
if [ -z "$noexec" ]; then
	ok "every script is executable"
else
	# `git update-index --chmod=+x` rather than chmod: the mode has to be in the
	# index, or it is right locally and wrong for everyone who clones.
	bad "not executable:$noexec"
	printf '    fix with: git update-index --chmod=+x <file>\n'
fi

# ------------------------------------------------------------------------------
say "ShellCheck"
# ------------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
	out=$(git ls-files 'bin/*.sh' 'apps/*/scripts/*.sh' 'host/greenboot/*.sh' | xargs -r shellcheck -x 2>&1)
	if [ -z "$out" ]; then
		ok "clean"
	else
		bad "shellcheck findings"
		echo "$out" | head -40 | sed 's/^/    /'
	fi
else
	skip "shellcheck is not installed"
fi

# ------------------------------------------------------------------------------
say "Check ids"
# ------------------------------------------------------------------------------
# bin/verify-host.sh writes status.json, in which every finding is keyed by a
# hand-written dotted id.
#
# WHAT IS *NOT* CHECKED HERE, and why: id uniqueness. An id legitimately appears
# several times in the source - once per branch of the same check, which is the
# design, since an id that speaks only on failure is indistinguishable from a
# check that did not run. The real invariant is "at most once per RUN", which is
# a runtime property; verify-host.sh asserts it itself at emit time. A static
# uniq -d here flags every correctly-written check, which is worse than nothing.
#
# What IS checkable statically is the shape. A malformed id means a message was
# passed in the id position - the whole finding then keys on a sentence, which
# is exactly what the id exists to avoid.
vh=bin/verify-host.sh
if [ -f "$vh" ]; then
	# Every literal argument in the id position, however spelled.
	malformed=$(grep -oE '^[[:space:]]*(ok|bad|warn|note) [^"$][^ ]*' "$vh" \
		| awk '{print $2}' | grep -vE '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' || true)
	n=$(grep -coE '\b(ok|bad|warn|note) ([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*|"\$)' "$vh" || true)
	if [ -n "$malformed" ]; then
		bad "malformed check id(s) in $vh: $(printf '%s' "$malformed" | tr '\n' ' ')"
	else
		ok "$n check ids, all well-formed"
	fi
else
	skip "no $vh"
fi

# ------------------------------------------------------------------------------
say "Topology"
# ------------------------------------------------------------------------------
# apps/dashboard/src/topology.ts is a SECOND COPY of the Network=, Pod= and
# PublishPort= lines in stacks/. CLAUDE.md has a name for that shape - when it
# rejects split-horizon DNS it calls a hand-maintained duplicate of the
# Caddyfile's site blocks "the most driftable shape this repository has a name
# for" - and the objection is correct.
#
# The duplicate exists because no container may run `podman network inspect`:
# the podman socket is SELinux-denied from container_t, which is the same
# constraint that makes the whole dashboard read-only. Discovering the topology
# at run time is not available, and these files ARE the authority anyway.
#
# So it is allowed to exist only on condition that it cannot quietly become
# fiction. This leg parses both and fails on any difference. A drawing of the
# network that is wrong is worse than no drawing at all, because it is used to
# reason about what can reach what.
topo=apps/dashboard/src/topology.ts
if [ -f "$topo" ] && command -v python3 >/dev/null 2>&1; then
	drift=$(python3 - "$topo" <<-'PY'
		import re, sys, pathlib

		topo = pathlib.Path(sys.argv[1]).read_text()

		# --- what stacks/ actually declares ---------------------------------
		declared = {}
		pods = {}
		published = set()
		for path in sorted(pathlib.Path("stacks").rglob("*")):
		    if path.suffix not in (".container", ".pod"):
		        continue
		    text = path.read_text()
		    name = re.search(r"^\s*(?:ContainerName|PodName)=(.+)$", text, re.M)
		    if not name:
		        continue
		    name = name.group(1).strip()
		    declared[name] = {
		        m.group(1).strip().removesuffix(".network")
		        for m in re.finditer(r"^\s*Network=(.+)$", text, re.M)
		    }
		    pod = re.search(r"^\s*Pod=(.+)$", text, re.M)
		    if pod:
		        pods[name] = pod.group(1).strip().removesuffix(".pod")
		    for m in re.finditer(r"^\s*PublishPort=(.+)$", text, re.M):
		        # Keep only the container-side port: the host side is a ${VAR}
		        # and the bind address is another, neither of which this file
		        # can resolve. What matters is that a publish EXISTS.
		        published.add((name, m.group(1).strip().rsplit(":", 1)[-1]))

		networks = {
		    p.stem for p in pathlib.Path("stacks").rglob("*.network")
		}

		# --- what topology.ts claims ---------------------------------------
		ts_networks = set(re.findall(r'id:\s*"([^"]+)"', topo))

		ts_nodes = {}
		ts_pods = {}
		ts_published = set()
		for block in re.finditer(
		    r'name:\s*"([^"]+)"[^}]*?networks:\s*\[([^\]]*)\]([^}]*)', topo, re.S
		):
		    node = block.group(1)
		    ts_nodes[node] = set(re.findall(r'"([^"]+)"', block.group(2)))
		    tail = block.group(3)
		    pod = re.search(r'pod:\s*"([^"]+)"', tail)
		    if pod:
		        ts_pods[node] = pod.group(1)
		    pub = re.search(r"publishes:\s*\[([^\]]*)\]", tail, re.S)
		    if pub:
		        for mapping in re.findall(r'"([^"]+)"', pub.group(1)):
		            ts_published.add((node, mapping.split("->")[-1].strip()))

		problems = []

		for missing in sorted(networks - ts_networks):
		    problems.append(f"network {missing} is in stacks/ and not in topology.ts")
		for extra in sorted(ts_networks - networks):
		    problems.append(f"network {extra} is in topology.ts and not in stacks/")

		for missing in sorted(set(declared) - set(ts_nodes)):
		    problems.append(f"container {missing} is in stacks/ and not in topology.ts")
		for extra in sorted(set(ts_nodes) - set(declared)):
		    problems.append(f"container {extra} is in topology.ts and not in stacks/")

		for node in sorted(set(declared) & set(ts_nodes)):
		    if declared[node] != ts_nodes[node]:
		        want = " ".join(sorted(declared[node])) or "(none)"
		        got = " ".join(sorted(ts_nodes[node])) or "(none)"
		        problems.append(f"{node} networks: stacks/ says [{want}], topology.ts says [{got}]")

		if pods != ts_pods:
		    problems.append(f"pod membership: stacks/ says {pods}, topology.ts says {ts_pods}")

		if published != ts_published:
		    problems.append(
		        f"published ports: stacks/ says {sorted(published)}, "
		        f"topology.ts says {sorted(ts_published)}"
		    )

		print("\n".join(problems))
	PY
	)
	if [ -z "$drift" ]; then
		ok "topology.ts matches stacks/"
	else
		bad "topology.ts has drifted from stacks/"
		printf '%s\n' "$drift" | sed 's/^/    /'
	fi
elif [ ! -f "$topo" ]; then
	skip "no $topo"
else
	skip "python3 is not installed"
fi

# ------------------------------------------------------------------------------
say "Quadlets"
# ------------------------------------------------------------------------------
# Catches syntax errors, NOT unset variables - systemd expands an unset ${VAR}
# to an empty string and logs it at info level, so those only surface at runtime.
QUADLET=/usr/libexec/podman/quadlet
if [ -x "$QUADLET" ]; then
	if QUADLET_UNIT_DIRS="$PWD/stacks/common:$PWD/stacks/torrent:$PWD/stacks/media:$PWD/stacks/infra" \
		"$QUADLET" -dryrun -user >/dev/null 2>&1; then
		ok "$(git ls-files 'stacks/*' | grep -cE '\.(container|network|pod|build)$') units generate"
	else
		bad "quadlet -dryrun failed"
	fi
else
	skip "no quadlet generator at $QUADLET"
fi

echo
if [ "$fails" -gt 0 ]; then
	printf '\033[31m%d check(s) FAILED\033[0m\n' "$fails"
	exit 1
fi
printf '\033[32mall checks passed\033[0m\n'
