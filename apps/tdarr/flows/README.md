# Tdarr flows

**A record, not a deployment.** Unlike `apps/tdarr/plugins/`, nothing copies these into the
container: Tdarr has no import-a-flow-from-disk mechanism, so the flow that actually runs lives in
`config/tdarr/server/Tdarr/DB2/SQL/database.db` and is edited in Tdarr's own flow editor.

They are tracked anyway, for the reason everything else here is tracked: a flow is real
configuration - it decides what happens to every file in the library - and it was previously
recoverable from nothing but a backup of gitignored runtime state. A `git grep` did not find it, a
diff could not show what changed, and the only way to review one was to open the UI.

`avsOnePass1.json` is the flow all four libraries use. The `htpX8Ypt1` community flow it replaced is
still in Tdarr, unused, as the rollback - see CLAUDE.md.

## Re-exporting after an edit

```bash
ssh home.local 'podman exec tdarr-server curl -sf -X POST -H "Content-Type: application/json" \
  -d "{\"data\":{\"collection\":\"FlowsJSONDB\",\"mode\":\"getById\",\"docID\":\"avsOnePass1\"}}" \
  http://localhost:8266/api/v2/cruddb' | jq -aS . > apps/tdarr/flows/avsOnePass1.json
```

**`jq -a`, not plain `jq`.** The node names carry emoji, and `bin/lint-repo.sh` asserts every tracked
text file is ASCII. `-a` escapes them as `\uXXXX`, which is the same JSON document - verified by
diffing the two parsed forms - and keeps the file readable in review.

## What the graph is, and the trap in it

Nine nodes. The happy path is `aStart -> aPolicy -> aStats -> aSize -> aHealth -> aMoveDone ->
aDelete`, with `aSize` and `aHealth` diverting to `aMoveRev -> aReview` when the output looks wrong.

**`aPolicy` has two outputs and both must be wired.** It is
`runClassicTranscodePlugin` 2.0.0 wrapping `Local:Tdarr_Plugin_avs1_MediaStackStreamPolicy`, and it
returns `outputNumber: 1` when it transcoded and **`outputNumber: 2` when the file was already
compliant and needs no work**. Output 2 was unwired until 2026-08-14, so every already-HEVC file
under the 8 Mbps threshold hit a dead end: Tdarr recorded `Not required`, the flow stopped, and
`aMoveDone` never ran, so the file stayed in `queued/` where Jellyfin does not look. *The Hobbit: The
Battle of the Five Armies* sat there for a day, with Radarr, Tdarr and Jellyfin each individually
correct.

Output 2 now goes to **`aMoveKeep`, a SECOND mover node that nothing follows** - not to `aMoveDone`.
It skips `aStats`, `aSize` and `aHealth` deliberately: there is no new output to recompute statistics
for, comparing a file's size against itself is meaningless, and `aHealth` is a full-file decode -
which on this branch would run against the source **on the spindle**, since nothing was ever staged
to the NVMe cache. That is the operation that took the whole host down once already.

**The second node exists because reusing `aMoveDone` does not work, and this was measured rather
than reasoned about.** `aMoveDone` is followed by `aDelete`, which is configured
`fileToDelete: originalFile`. On the transcoded branch the original (in `queued/`) and the working
file (the cache output) are different files, so deleting the original is right. On the compliant
branch **they are the same file** - so `aMoveDone` moves it and `aDelete` then tries to `unlink` a
path that no longer exists:

```
Deleting original file /media/library/queued/movies/.../The Hobbit ... (2014).mkv
Error: ENOENT: no such file or directory, unlink '/media/library/queued/movies/...'
Flow has failed
Successfully updated server with verdict: transcodeError
```

**No data is lost** - the move is a rename within one filesystem, so the inode and its hardlink to
`downloads/` survive, verified by `stat` - but every already-compliant file would be recorded as a
`Transcode error` for ever. Ending the branch at its own mover produces `Transcode success` and a
clean job report, confirmed against *The Punisher: One Last Kill*:

```
Found next plugin: avsOnePass1::aStart
Found next plugin: avsOnePass1::aPolicy
Found next plugin: avsOnePass1::aMoveKeep
Attempting move from /media/library/queued/... to /media/library/transcoded/...
After move/copy, destination file of size 1478772580 does match
```

There is nothing to delete on this branch, which is why the flow simply ends.

**An unwired output fails silently and looks like success**, which is the general lesson: after
changing a flow, check that files leave `queued/`, not just that the job reports say `success` -
and equally, check the *verdict*, because a flow can move the file correctly and still record an
error on a later node.
