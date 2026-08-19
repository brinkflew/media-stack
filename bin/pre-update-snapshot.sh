#!/usr/bin/env bash
# ==============================================================================
# Snapshot every database immediately before the nightly container update
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as ExecStartPre= on podman-auto-update.service. There is
# little reason to run it by hand.
#
# WHAT THIS EXISTS FOR, in one sentence: podman auto-update's rollback restores
# the IMAGE and cannot un-migrate the DATABASE, so for every application here
# that migrates a schema on startup the safety net is itself the failure mode.
#
# It is not hypothetical. On the night of 2026-08-18 Pocket ID 2.14.0 started,
# migrated its SQLite schema, and failed its health probe - because the probe
# shelled out to `curl` and 2.14.0 had stopped shipping it. auto-update did
# exactly what it is designed to do and rolled the image back to 2.13.0, which
# could no longer open the schema 2.14.0 had just written:
#
#   database version (20260814120000) is newer than application version
#   (20260802120000), downgrades are not allowed
#
# Nine and a half hours of no sign-on anywhere in the stack, at restart 6,223.
# Sonarr, Radarr, Prowlarr, Bazarr, Jellyfin, Jellyseerr, Tdarr and ntfy all
# carry databases and all follow a moving tag, so all of them can be rolled back
# into a schema their restored image cannot read.
#
# THE TIMING IS THE WHOLE POINT, and it is why the nightly backup does not
# already cover this. podman-auto-update.timer is OnCalendar=daily with
# RandomizedDelaySec=900, so it fires at ~00:00-00:15.
# home-server-backup.timer is 03:00. The updater therefore runs TWENTY-ONE
# HOURS after the newest snapshot, and a rollback at 00:20 has nothing newer
# than the previous morning to restore from. This closes that window to seconds.
#
# IT WRITES TO ITS OWN SHADOW TREE, deliberately not the backup's. They would
# otherwise overwrite each other three hours apart and the pre-update copy would
# be the one that lost - which is the copy that matters at the moment a rollback
# has just failed. Like the backup's shadow it is NOT deleted between runs, so
# each night only rewrites the pages that changed.
#
# IT IS ALLOWED TO ABORT THE UPDATE. The drop-in carries no `-` prefix, so a
# failure here means podman auto-update never runs and the unit goes red. That
# is the intended direction: not updating for a night is recoverable, updating
# with no way back is what produced the outage above. It affects CONTAINER
# updates only - the OS updater is rpm-ostreed-automatic and
# bin/reboot-when-staged.sh is untouched, so this can never hold up an OS
# security update.
#
# See also: bin/snapshot-databases.sh, which does the actual work and explains
# why a live SQLite file cannot simply be copied.
# ==============================================================================

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

CONFIG="${1:-$ROOT/config}"
SHADOW="${2:-$HOME/.cache/home-server/pre-update-db}"
STATE="${HOME_SERVER_BACKUP_STATE:-$HOME/.cache/home-server/backup-state}"

"$ROOT/bin/snapshot-databases.sh" "$CONFIG" "$SHADOW"

# The marker goes into the SAME file bin/backup-server.sh keeps its markers in,
# so bin/verify-host.sh has one place to read rather than two.
#
# READ-MODIFY-WRITE PRESERVING EVERY OTHER KEY, because both writers rewrite
# this file whole. backup-server.sh names the keys it carries forward one by
# one, and pre_update_db_at is in that list - drop it there and this marker
# silently disappears at 03:00 every night, which reads as "the pre-update
# snapshot has stopped running" while it is in fact running perfectly.
mkdir -p "$(dirname "$STATE")"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
	grep -vE '^pre_update_db_at=' "$STATE" 2>/dev/null || true
	echo "pre_update_db_at=$now"
} >"$STATE.tmp"
mv "$STATE.tmp" "$STATE"

echo "pre-update database snapshot complete: $SHADOW"
