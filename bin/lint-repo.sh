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
