#!/usr/bin/env bash
# ==============================================================================
# Copy the local restic repository to Scaleway Object Storage
# ------------------------------------------------------------------------------
# RUNS ON THE WORKSTATION, after bin/backup-config.sh. It copies an existing
# repository rather than backing up again, so the server is touched not at all
# and the two repositories hold identical, verifiable snapshots.
#
# THIS IS THE ONLY THING THAT SURVIVES LOSING THE WORKSTATION. Everything else
# lives here: the restic repository, both age private keys, the restic
# passwords. bin/backup-config.sh covers the server's disk dying; this covers
# the laptop being stolen, dropped, or encrypted by something unpleasant.
#
# The credentials deliberately do NOT go in sops or anywhere the server can
# read. The server has no route to the backups and no credentials for them, and
# that is what stops a compromised server from reaching them - the same reason
# bin/backup-config.sh pulls instead of pushing. Adding these to secrets/ would
# undo it.
#
# `restic copy` re-encrypts blob by blob, so the destination has its OWN
# password. Compromising one credential loses one copy. It does mean the two
# repositories do not deduplicate against each other, which costs nothing here:
# the whole thing is 1.4 GiB.
#
# Setup, once - see the block printed if the config is missing:
#   ~/.config/restic/media-stack-offsite.env   bucket, region and API keys
#   ~/.config/restic/media-stack-offsite.pw    the destination password
#
# Usage:  bin/backup-offsite.sh [--check]
#           --check   also verify the destination's structure after copying
# ==============================================================================

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

SRC_REPO="${RESTIC_REPOSITORY:-$HOME/backups/media-stack}"
SRC_PW="${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/media-stack.pw}"
DST_ENV="${MEDIA_STACK_OFFSITE_ENV:-$HOME/.config/restic/media-stack-offsite.env}"
DST_PW="${MEDIA_STACK_OFFSITE_PW:-$HOME/.config/restic/media-stack-offsite.pw}"
CHECK=""
[ "${1:-}" = "--check" ] && CHECK=1

die() { printf '\033[31mbackup-offsite: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

command -v restic >/dev/null || die "restic is not on PATH"
[ -d "$SRC_REPO" ] || die "no local repository at $SRC_REPO - run bin/backup-config.sh first"
[ -s "$SRC_PW" ]   || die "no local repository password at $SRC_PW"
[ -s "$DST_PW" ]   || die "no destination password at $DST_PW"

if [ ! -s "$DST_ENV" ]; then
  cat >&2 <<EOF

  No destination configured at
      $DST_ENV

  Create it with a Scaleway bucket and an API key scoped to that bucket only:

      RESTIC_REPOSITORY=s3:https://s3.fr-par.scw.cloud/<your-bucket>
      AWS_ACCESS_KEY_ID=SCW...
      AWS_SECRET_ACCESS_KEY=...

  Then: chmod 600 $DST_ENV

  Regions: fr-par (Paris), nl-ams (Amsterdam), pl-waw (Warsaw). The endpoint
  must match the region the bucket was created in, or the first call fails with
  a bare 403 rather than anything about regions.

EOF
  exit 1
fi

# The credentials file is sourced, so it must not be readable by anyone else and
# must not be a symlink into somewhere surprising.
perms=$(stat -c %a "$DST_ENV")
[ "$perms" = "600" ] || die "$DST_ENV is mode $perms, expected 600 - it holds API keys"

set -a; . "$DST_ENV"; set +a
[ -n "${RESTIC_REPOSITORY:-}" ]     || die "$DST_ENV does not set RESTIC_REPOSITORY"
[ -n "${AWS_ACCESS_KEY_ID:-}" ]     || die "$DST_ENV does not set AWS_ACCESS_KEY_ID"
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "$DST_ENV does not set AWS_SECRET_ACCESS_KEY"
DST_REPO="$RESTIC_REPOSITORY"

# ------------------------------------------------------------------------------
# 1. Initialise the destination if this is the first run
# ------------------------------------------------------------------------------
say "destination: $DST_REPO"
if restic -r "$DST_REPO" --password-file "$DST_PW" cat config >/dev/null 2>&1; then
  echo "  repository exists"
else
  echo "  not initialised - creating it"
  restic -r "$DST_REPO" --password-file "$DST_PW" init \
    || die "init failed. A 403 here usually means the endpoint region does not
  match the bucket's, or the API key is not scoped to this bucket."
fi

# ------------------------------------------------------------------------------
# 2. Copy
# ------------------------------------------------------------------------------
# copy is idempotent: snapshots already present are skipped by ID, so this is
# safe to re-run and cheap when nothing has changed.
say "copying snapshots"
restic -r "$DST_REPO" --password-file "$DST_PW" copy \
  --from-repo "$SRC_REPO" --from-password-file "$SRC_PW"

# ------------------------------------------------------------------------------
# 3. Retention, matching the local policy
# ------------------------------------------------------------------------------
# Applied here as well as locally because copy does not replicate deletions -
# without this the off-site repository grows for ever.
say "pruning"
restic -r "$DST_REPO" --password-file "$DST_PW" forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12

if [ -n "$CHECK" ]; then
  say "verifying"
  restic -r "$DST_REPO" --password-file "$DST_PW" check
fi

say "off-site snapshots"
restic -r "$DST_REPO" --password-file "$DST_PW" snapshots --compact | tail -6
