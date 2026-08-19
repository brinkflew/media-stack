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
say "Secrets"
# ------------------------------------------------------------------------------
# THE RECIPIENT LIST DRIFTS SILENTLY AND NOTHING NOTICED. .sops.yaml warns in its
# own header that adding a recipient does NOT re-encrypt existing files - you
# have to run `sops updatekeys secrets/env.sops.env` yourself - so the rules file
# and the encrypted file can disagree indefinitely while every commit looks fine.
# Two ways that hurts, and neither announces itself: a key added to .sops.yaml
# but never applied cannot decrypt anything, discovered at the moment a machine
# is being rebuilt; and a key REMOVED from .sops.yaml but still on the file is a
# revocation that did not happen.
#
# TEXT ONLY, DELIBERATELY. This compares the age recipients named in the two
# files and never decrypts, so it needs no private key and runs anywhere - which
# is what lets it live in the linter rather than only on a machine that holds a
# key. Whether the server can actually USE its key is a different question and a
# different check: secrets.decryptable in bin/verify-host.sh.
if [ ! -f .sops.yaml ] || [ ! -f secrets/env.sops.env ]; then
	skip "no .sops.yaml or secrets/env.sops.env"
else
	want=$(grep -oE 'age1[a-z0-9]+' .sops.yaml | sort -u)
	have=$(grep -oE 'recipient=age1[a-z0-9]+' secrets/env.sops.env \
		| sed 's/^recipient=//' | sort -u)
	if [ -z "$want" ]; then
		bad ".sops.yaml names no age recipients"
	elif [ "$want" = "$have" ]; then
		ok "secrets/env.sops.env is encrypted for all $(printf '%s\n' "$want" | wc -l | tr -d ' ') recipients in .sops.yaml"
	else
		missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
		extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
		# tr rather than an unquoted expansion. The keys belong on one line,
		# and letting the shell word-split them is not how to say so - SC2086
		# is right about that. (A comment line may not BEGIN with the linter's
		# own name either: that parses as a directive and fails with SC1072.)
		[ -z "$missing" ] || bad "in .sops.yaml but NOT on the encrypted file: $(printf '%s' "$missing" | tr '\n' ' ')- run: sops updatekeys secrets/env.sops.env"
		[ -z "$extra" ] || bad "on the encrypted file but NOT in .sops.yaml: $(printf '%s' "$extra" | tr '\n' ' ')- a revoked key still decrypts this; run: sops updatekeys secrets/env.sops.env"
	fi
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
say "Paths"
# ------------------------------------------------------------------------------
# apps/dashboard/src/paths.ts is the second hand-maintained duplicate here and
# the more dangerous one, because it cannot be derived in full. Half of these
# edges live in Sonarr's, Radarr's, Prowlarr's, Bazarr's and Jellyseerr's own
# databases - CLAUDE.md says it outright about the download client: "a git grep
# does not find them and a restore brings the old value back."
#
# So this leg VALIDATES rather than diffs, and the check it can make is the one
# that matters: every bridge carries Options=isolate=true, so two containers
# that share no segment have no route to each other. An edge between them is a
# drawing of a path that cannot exist - and a drawing of the network that is
# wrong is worse than none, because it is used to reason about what can reach
# what.
#
# It deliberately does NOT check which segment carries an edge, because paths.ts
# deliberately does not say: caddy and sonarr share net-arr AND net-download,
# and which one podman's DNS resolves at connect time is observable nowhere. The
# intersection is derived at render time and rendered as ambiguity.
#
# THE FLOOR IS NOT DECORATION. A regex that stops matching prints nothing and
# passes, which is indistinguishable from a clean run - the same shape as the
# ShellCheck leg that once reported "all checks passed" over 2,224 lines it had
# never read. (Note the capital: a comment opening with the lowercase name is
# read as a directive by the very tool it is describing, which fails this file's
# own ShellCheck leg. That is a small joke at nobody's expense.) So the parse
# counts what it found and refuses a file with implausibly few edges in it.
paths=apps/dashboard/src/paths.ts
topo=apps/dashboard/src/topology.ts
if [ -f "$paths" ] && [ -f "$topo" ] && command -v python3 >/dev/null 2>&1; then
	drift=$(python3 - "$paths" "$topo" <<-'PY'
		import re, sys, pathlib

		# Raise this when edges are added. It exists so that a parse which has
		# stopped matching reads as a failure rather than as a clean run.
		MIN_PATHS = 39

		paths = pathlib.Path(sys.argv[1]).read_text()
		topo = pathlib.Path(sys.argv[2]).read_text()
		problems = []

		# topology.ts is parsed again rather than shared with the leg above: that
		# one proves it matches stacks/, this one only needs the node table it
		# has just been proved to hold. Sharing state would make one failure
		# read as both.
		nodes, pods = {}, {}
		for block in re.finditer(
		    r'name:\s*"([^"]+)"[^}]*?networks:\s*\[([^\]]*)\]([^}]*)', topo, re.S
		):
		    nodes[block.group(1)] = set(re.findall(r'"([^"]+)"', block.group(2)))
		    pod = re.search(r'pod:\s*"([^"]+)"', block.group(3))
		    if pod:
		        pods[block.group(1)] = pod.group(1)
		if not nodes:
		    problems.append("topology.ts parsed to ZERO nodes - every check below would pass vacuously")

		pseudo = set(re.findall(r'^\s*(\w+): "[^"]*(?:inbound|outbound)[^"]*",\s*$', paths, re.M))
		if not pseudo:
		    problems.append("paths.ts declares no PSEUDO_NODES - a terminal edge would read as a broken one")

		# Records are split on the OPENING brace, never a closing one: a `why`
		# legitimately contains "}" - "torrent:{$PORT_JOAL_WEB}" does - so any
		# non-greedy {...} parse truncates records and reports nothing.
		body = paths.split("export const PATHS", 1)
		section = body[1] if len(body) == 2 else ""
		if not section:
		    problems.append("paths.ts has no `export const PATHS` - the parse below would find nothing and say nothing")
		opens = len(re.findall(r"^\s*\{ from:", section, re.M))

		edges = []
		for chunk in re.split(r"^\s*\{(?=\s*from:)", section, flags=re.M)[1:]:
		    rec = {}
		    for key in ("from", "to", "why", "source"):
		        m = re.search(r'\b%s: "((?:[^"\\]|\\.)*)"' % key, chunk)
		        if m:
		            rec[key] = m.group(1)
		    if len(rec) == 4:
		        edges.append(rec)

		if opens != len(edges):
		    problems.append(
		        f"paths.ts: {opens} record(s) open with `from:` but only {len(edges)} "
		        "parsed with all four fields - every edge needs from, to, why and source"
		    )
		if len(edges) < MIN_PATHS:
		    problems.append(
		        f"paths.ts parsed to {len(edges)} edge(s), floor is {MIN_PATHS} - either the "
		        "file has shrunk or the parse has stopped matching, and those look identical here"
		    )

		bad_source = sorted({e["source"] for e in edges} - {"git", "runtime"})
		if bad_source:
		    problems.append("paths.ts: unknown source " + " ".join(bad_source) + " - it is a closed set")

		def reach(node):
		    """Which segments a node can actually use. A pod member declares
		    networks: [] and reaches the world through its pod's, which is the
		    entire point of the pod."""
		    if node not in nodes:
		        return None
		    return nodes[node] | nodes.get(pods.get(node, ""), set())

		terminals = crossed = ambiguous = 0
		for e in edges:
		    frm, to = e["from"], e["to"]
		    for end in (frm, to):
		        if end not in nodes and end not in pseudo:
		            problems.append(f"edge {frm} -> {to}: {end} is in neither topology.ts NODES nor PSEUDO_NODES")
		    if frm in pseudo or to in pseudo:
		        terminals += 1
		        continue
		    a, b = reach(frm), reach(to)
		    if a is None or b is None:
		        continue
		    if pods.get(frm) and pods.get(frm) == pods.get(to):
		        # One namespace, not one network. Their networks lists are both
		        # empty and intersect to nothing, which is not a violation - it
		        # is the tightest coupling in the stack.
		        continue
		    shared = a & b
		    if not shared:
		        problems.append(
		            f"edge {frm} -> {to} crosses no shared segment: stacks/ puts {frm} on "
		            f"[{' '.join(sorted(a)) or '(none)'}] and {to} on [{' '.join(sorted(b)) or '(none)'}]. "
		            "Every bridge is isolate=true, so that route cannot exist"
		        )
		    else:
		        crossed += 1
		        if len(shared) > 1:
		            ambiguous += 1

		if not problems:
		    runtime = sum(1 for e in edges if e["source"] == "runtime")
		    print("OK %d edges (%d runtime-only, %d terminal), %d cross a shared segment, "
		          "%d of those share more than one" % (len(edges), runtime, terminals, crossed, ambiguous))
		else:
		    print("\n".join(problems))
	PY
	)
	case "$drift" in
	OK\ *) ok "paths.ts: ${drift#OK }" ;;
	*)
		bad "paths.ts does not describe this topology"
		printf '%s\n' "$drift" | sed 's/^/    /'
		;;
	esac
elif [ ! -f "$paths" ]; then
	skip "no $paths"
else
	skip "python3 is not installed"
fi

# ------------------------------------------------------------------------------
say "Quadlets"
# ------------------------------------------------------------------------------
# Catches syntax errors, NOT unset variables - systemd expands an unset ${VAR}
# to an empty string and logs it at info level, so those only surface at runtime.
# Overridable, because this path is packaging-dependent: it is where Fedora and
# uCore put the standalone generator, and a CI runner on another distribution
# may not agree. NOT the podman-user-generator path - see CLAUDE.md, the wrong
# one fails with "No such file or directory" and reads as unavailable rather
# than as misspelled.
QUADLET="${QUADLET:-/usr/libexec/podman/quadlet}"
if [ -x "$QUADLET" ]; then
	if qout=$(QUADLET_UNIT_DIRS="$PWD/stacks/common:$PWD/stacks/torrent:$PWD/stacks/media:$PWD/stacks/infra" \
		"$QUADLET" -dryrun -user 2>&1); then
		ok "$(git ls-files 'stacks/*' | grep -cE '\.(container|network|pod|build)$') units generate"
	else
		# SHOW THE ERROR. This said only "quadlet -dryrun failed" until
		# 2026-08-19, which is useless anywhere the generator disagrees with
		# this workstation - and that is exactly where it first fired, on a CI
		# runner whose podman is older than the host's and rejects a directive
		# that is valid here. A linter that will not say what it found sends
		# you to reproduce its own run by hand.
		bad "quadlet -dryrun failed"
		# FILTER THE CHATTER BEFORE TRUNCATING, not after. The generator logs
		# "Loading source unit file" for all 35 units and the real complaint
		# comes last, so a plain `head` shows nothing but the preamble - and
		# closing the pipe early makes both grep and printf report a broken
		# pipe, which then looks like the failure. That is what the first CI
		# run produced.
		printf '%s\n' "$qout" \
			| grep -avE '^$|Loading source unit file' \
			| tail -20 | sed 's/^/    /'
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
