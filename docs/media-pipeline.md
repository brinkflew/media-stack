# The media pipeline

Lifted whole from `CLAUDE.md` on 2026-08-19. Nothing here was rewritten.

From what the \*arr apps import, through Tdarr, to what Jellyfin serves - and the seeding policy
at the other end. Several entries here record failures where every visible signal read green.

## From queued/ to transcoded/

**The library is a pipeline, not a folder.** `library/queued/<type>` is where the \*arr apps import
to, Tdarr transcodes, and Jellyfin serves *only* `library/transcoded/<type>`. `<type>` is one of
`anime`, `documentaries`, `movies`, `series`; `review/` is the manual siding and `.recycle` is the
\*arr recycle bin, deliberately outside every Jellyfin library path. A root folder that omits the
`queued/` or `transcoded/` level exists nowhere on disk - which is how Jellyseerr came to file every
request into three paths that did not exist, so nothing requested through it could import at all.
**Check a new root folder against the disk, not against what looks plausible.**

**Tdarr's flow DOES promote the file; what was missing is telling the \*arr apps.** The old five-flow
chain transcoded in place and left everything in `queued/`, which is where the "correctly downloaded,
correctly imported, correctly transcoded, invisible in Jellyfin" failure came from. `avsOnePass1`
ends in a `moveToDirectory` node reading `{{{args.userVariables.library.output_dir_done}}}`, and
**every library defines that** - `/media/library/transcoded/<type>`. So the file moves itself.

**Those variables live in the `variablesjsondb` table, keyed `library:<id>`, not on the library
document.** `LibrarySettingsJSONDB` reports `userVariables: null` for all four libraries, which makes
the flow look broken when it is not. Read them with:

```bash
podman exec tdarr-server curl -sf -X POST -H 'Content-Type: application/json' \
  -d '{"data":{"collection":"VariablesJSONDB","mode":"getAll"}}' \
  http://localhost:8266/api/v2/cruddb | jq -r 'sort_by(.type,.key)[]|"\(.type) \(.key)=\(.value)"'
```

**THE FLOW COLLECTION IS `FlowsJSONDB`, PLURAL, and the singular is the trap.** `FlowJSONDB` is
accepted, answers 200 and returns an EMPTY BODY - so a wrong name reads as "this Tdarr has no
flows" rather than as an error, which is the same shape as the `userVariables: null` above and
costs the same half hour. `checkout.tdarr_flows` in `bin/verify-host.sh` reads the plural one, and
`apps/tdarr/flows/` is compared against it hourly - the export is enforced now rather than
remembered. Note that the export and the database differ harmlessly in two places: every edge in
the export carries `animated` and `type: smoothstep` which the database omits, and node positions
move whenever anyone drags a box, so both are normalised away before comparing.

`bin/promote-transcoded.py` therefore reconciles rather than promotes: it tells Radarr and Sonarr
where Tdarr already put the file. Run every 10 minutes by `home-server-promote.timer`.

**It covers all four types, and each needs BOTH root folders to exist.** Radarr owns
`movies` + `documentaries`, Sonarr owns `series` + `anime`. It used to handle one type per
application, so a transcoded documentary moved to `transcoded/documentaries` and Radarr was never
told - the same failure, in a folder nobody watches. The script now refuses per type, loudly, when
the target is not a configured root folder, because the *arr editor call silently rejects a path the
application does not know.

It runs **on the host, not in a container**, and that is the design rather than an accident:
`net-transcode` is `isolate=true` and holds only Caddy and the two Tdarr containers, so Tdarr
cannot reach Radarr, Sonarr or Jellyfin and should not be able to. `podman exec` works regardless of
network topology, so the reconciler grants no container any reachability it did not have.

**It never touches a media file.** It reads the filesystem to see where each film actually is, then
calls the \*arr editor endpoints with `moveFiles: false` plus a rescan - the flow has *already* moved
the file, so the applications only need to be told. Anything that moves a file behind an \*arr's back
orphans it, which is what left *Flow* and *The Hobbit* in `transcoded/` while Radarr reported
`hasFile=false`. **Do not add a step that moves media directly.**

**It decides "has this moved?" by looking for a VIDEO FILE, never for the directory**, and that
distinction is the difference between working and silently doing nothing. It originally tested
`os.path.isdir()` on the queued folder. Tdarr does delete the film, with
`deleteParentFolderIfEmpty:true` - but the folder is not empty, because Radarr and Sonarr write
`fanart.jpg`, `poster.jpg` and a `.nfo` beside it. So the directory always survived, `gone` was never
true, and **the script never promoted a single file in its entire existence** while cheerfully
reporting "12 still in queued/, 0 moved by Tdarr". *Flow* and *The Hobbit* sat unmapped for nine
months as a result. If a reconciler here looks like it is working, check that it has actually done
something.

**It now names a STALL rather than reporting it as patience.** `gone=False, arrived=False` used to
be counted as "waiting on Tdarr", which is also what a live transcode looks like - so a file the
flow had abandoned was indistinguishable from one still being worked on, for ever. The script now
also reads Tdarr's `FileJSONDB` and prints `STUCK:` when a file still sitting in `queued/` already
carries a finished verdict (`Not required` or `Transcode success`). The Tdarr call is best-effort:
if it fails the set comes back empty and the script behaves exactly as it did before, because a
diagnostic must never be able to break the reconciliation it annotates.

## The flow trap: an unwired output silently eats the file

**A classic plugin's "nothing to do" answer is a SEPARATE flow output, and it must be wired.**
`runClassicTranscodePlugin` **2.0.0** returns `outputNumber: 1` when it transcoded and
**`outputNumber: 2` when the file was already compliant**. `avsOnePass1` wired only output 1, so
every source that was already HEVC under the 8 Mbps threshold hit a dead end: Tdarr recorded
`Not required`, the flow ended before `aMoveDone`, and the file stayed in `queued/` where Jellyfin
does not look - while Radarr, Tdarr and Jellyfin were each individually correct and
`promote-transcoded.py` printed "1 waiting on Tdarr" every ten minutes. *The Hobbit: The Battle of
the Five Armies* and *The Punisher: One Last Kill* both went this way inside two days.

Version 1.0.0 returned `outputNumber: 1` on that branch, so the dangling edge was harmless until the
stack moved 2.55.01 -> 2.71.01. **A plugin version bump can make an unwired output load-bearing**,
and nothing warns you: the job report says the run finished, and the file simply does not move.

Output 2 now goes to **`aMoveKeep`, a second `moveToDirectory` node that nothing follows**, skipping
`aStats`, `aSize` and `aHealth` deliberately - there is no new output to recompute statistics for,
comparing a file's size against itself is meaningless, and `aHealth` is a full-file decode that on
this branch would run against the source **on the spindle**, since nothing was ever staged to the
NVMe cache. That is the operation that took the whole host down once already.

**Wiring output 2 into the existing `aMoveDone` does NOT work, and the reason is worth keeping.**
`aMoveDone` is followed by `aDelete`, configured `fileToDelete: originalFile`. On the transcoded
branch the original and the working file are different, so that is correct. On the compliant branch
**they are the same file**, so the move leaves nothing behind and `aDelete` fails with
`ENOENT ... unlink`, which Tdarr treats as `Flow has failed` and records as `transcodeError`. No data
is lost - a rename within one filesystem preserves the inode and its hardlink to `downloads/`,
verified with `stat` - but every compliant file would be filed as an error for ever. Tried on *The
Hobbit*, corrected, then confirmed clean on *The Punisher: One Last Kill*. **A flow can move the file
correctly and still record an error on a later node**, so check the verdict as well as the file.

## Tdarr's file tables are the QUEUE, not a history

**"Transcode success" and "Not required" are views over the current library file table**
(`filejsondb`), which this pipeline drains to zero on purpose: every library watches
`/media/library/queued/<type>` only, and the flow moves output to `transcoded/<type>`, outside every
watched folder - so the folder watcher reaps each file from the table as it is promoted.
`scanOnStart=True` makes the sweep run at every container start, which is why it looks like a reboot
wiped something.

**Nothing is lost, and there is nothing to fix.** `/app/server` is a host bind mount, and Tdarr 2.86
has migrated off NeDB to one SQLite file at `Tdarr/DB2/SQL/database.db`. The durable history is
`jobsjsondb` - 2,659 rows as of 2026-08-14, surfaced in the UI on the **Jobs tab**. That is where to
look; a short Transcode-success table means the queue is empty, which is the goal.

**The 27% lifetime error rate is history, not a live fault.** 689 of 710 `Transcode error` rows are
from March 2025 - the destructive community flow documented above - and the five in August 2026
predate the repointing to `avsOnePass1`. Check the month distribution before investigating.

## All four Tdarr libraries, and what differs between them

Movies, Documentaries, Series and Anime all run `avsOnePass1` with `processLibrary=true` and
`processHealthChecks=false` - the flow health-checks each output while it is still on the NVMe
cache, so a library-wide check would only add full-file decodes off the spindle, which is what
wedged the host once already.

Until 2026-08-14 the other three pointed at **`htpX8Ypt1`, the destructive community flow**, with
processing off. Enabling them without repointing would have been actively harmful, not merely
useless.

**The one thing that genuinely differs per library is the audio whitelist**, and it differs because
of anime. The transcode node reads
`audioLanguages = {{{args.userVariables.library.audio_languages}}}`:

| Library | `audio_languages` |
|---|---|
| Movies, Documentaries, Series | `eng,fra,fre,und` |
| Anime | `jpn,chi,zho,kor,eng,fra,fre,und` |

**Anime VO is not always Japanese** - donghua is Chinese, aeni Korean - so the list covers all three
plus English and French, which are wanted when a release carries them *alongside* the VO. Without
this the default whitelist would have dropped a Japanese track on any release that also had English,
since the plugin's "keep everything" safety net only fires when **nothing** matches. That is the
exact bug class the plugin exists to prevent, and it would have been silent.

Subtitles stay at the plugin default `eng,fra,fre` for every library.

**Radarr and Sonarr both hold two types**, so each needs four root folders in total; `transcoded/`
counterparts for documentaries and anime were missing entirely and were added the same day. Jellyfin
already had a library per type, each reading `transcoded/<type>`.

**Sonarr's anime scoring is a preference, not a rule.** `Lang: Dual Audio` scores 100 in the one
quality profile, so a dual-audio release wins between otherwise-equal candidates - but
`minFormatScore` and `cutoffFormatScore` are both **0**, so a subbed VO-only release is perfectly
acceptable and Sonarr will not hunt for an upgrade purely to get a dub. Note the profile's other
formats (the TRaSH `Anime_10_*` set) score up to **4000**, so any cutoff low enough to be reachable
is satisfied by the first release that arrives: expressing "keep looking until dual audio" would
mean rescoring the whole profile, not moving the cutoff. The enabled `Anime` release profile ignores
`\bdub(bed)?\b`, which is what stops a dub-only release replacing the VO.

## The transcode policy

**One ffmpeg pass, defined by one tracked plugin.** `apps/tdarr/plugins/Tdarr_Plugin_avs1_MediaStackStreamPolicy.js`
is a *classic* Tdarr plugin - deliberately, not a flow plugin: a flow plugin must live at
`Plugins/Local/FlowPlugins/<cat>/<name>/1.0.0/index.js` and the community ones reach `FlowHelpers`
through relative `require`s that **do not resolve from `Local/`**. A classic plugin is one file in
`Plugins/Local/`, its single `require('../methods/lib')` is correct there, and it returns the raw
ffmpeg argument string. The flow `avsOnePass1` is then only 7 nodes around it.

It is **tracked in git** and copied into the gitignored `config/` tree by an `ExecStartPre=` on
`tdarr-server.container`. Editing the copy on the server is pointless; it is overwritten every start.

Things in it that are not obvious and cost time to find:

- **The keyframe interval is PINNED at just over 6 seconds, and it is not a tuning knob.**
  `keyframeSeconds` (default 6) becomes `-g N -keyint_min N -no-scenecut 1`, with `N` derived from
  the source frame rate - 145 at 23.976 fps, 151 at 25, 181 at 29.97. Left to itself NVENC uses a
  250-frame cap plus adaptive I-frames at scene cuts, which produces gaps anywhere from 0.2 s to
  10.4 s and breaks browser playback outright - see the drift entry in `docs/known-state.md`.
  **`-no-scenecut 1` is the load-bearing half**: without it NVENC keeps inserting keyframes at cuts,
  the gaps fall back below 6 s and the whole failure returns. It works because `-rc-lookahead 32` is
  already set; the option is ignored without lookahead. The frame rate is parsed from
  `r_frame_rate`, which ffprobe reports as the **rational string** `"24000/1001"` - `parseFloat` on
  that yields 24000 and would put the interval out by a factor of a thousand.

  **It costs nothing; it SAVES about 5%.** Measured on the same 90 s clip at CQ 26, preset p6:
  19,989,619 bytes with the old arguments against **18,997,172 with the new ones**, and the keyframe
  gaps went from 1.6-6.0 s to a flat 6.047-6.048 s. An I-frame is far more expensive than the P and
  B frames it displaces, so dropping the adaptive ones more than pays for having no keyframe exactly
  on a cut. The expectation going in was a small loss; measure this sort of thing rather than
  reasoning about it.
- **10-bit is done with `-vf scale_cuda=format=p010le`, NOT `-pix_fmt p010le`.** With
  `-hwaccel_output_format cuda` the frames never leave GPU memory, so a pixel-format conversion has
  nowhere to happen and ffmpeg fails with *"Impossible to convert between the formats supported by
  the filter 'Parsed_null_0' and the filter 'auto_scale_0'"*. Do not "simplify" it back.
- **Opus bitrates are TOTAL, not per channel** - 128k stereo, 256k 5.1, 450k 7.1. The old flow
  multiplied by channel count and produced 1536k and 2048k Opus, which is why it made files *bigger*.
- **Opus only for codecs that do not direct-play** (truehd/dts/flac/pcm/mlp). AAC, AC3, E-AC3, MP3
  and Opus are copied: lossy->lossy is generation loss for nothing. Plain DTS *is* converted despite
  being lossy - it is badly supported and runs 768-1536 kb/s.
- **The AC3 companion is decided per LANGUAGE, not per file.** These releases carry French AC3 next
  to an English DTS-HD VO, so a per-file "does an AC3 exist?" test wrongly concludes yes and leaves
  the VO Opus-only - precisely the direct-play case the companion exists for.
- **Channel count is never a selection criterion.** The old flow filtered audio by "keep the highest
  channel count" *before* looking at language, which is what deleted VO tracks.
- Inside the container **only one GPU is visible, so the healthy card is ordinal 0**. `-gpu 1` and
  `-hwaccel_device 1` fail there with `CUDA_ERROR_INVALID_DEVICE`.

**CQ 26, calibrated not guessed.** Against a 20 Mbps VC-1 remux (60 s, preset p6, SSIM vs source):

| CQ | 20 | 22 | 24 | 26 | 28 |
|---|---|---|---|---|---|
| kbps | 9631 | 8618 | 6354 | 4541 | 3179 |
| SSIM | .98817 | .98771 | .98584 | .98379 | .98164 |

SSIM moves **0.0065 across a 3x bitrate range** - there is no cliff to find, so this is a storage
decision, not a technical one. `v_cq=18` was the old value and is near-lossless.

**A subtitle-inclusive benchmark cannot use `-t`.** Copying sparse PGS streams makes ffmpeg read the
*whole* file to flush them, so a 60-second test of a 22 GB film took 131 s instead of 9 s. Production
encodes the whole file anyway and pays nothing. Measure video-only, or measure the real thing.

## The Radarr [VO] profile encodes one rule: VO now, French when it appears

Profile 9 `[VO]` is the only Radarr profile that scores custom formats, and every film is on it.
The scoring says: **a VO-only release is acceptable, but keep looking until one carries French too,
then stop.**

| Setting | Value | Why |
|---|---|---|
| `minFormatScore` | 30 | The floor. **It was unreachable until 2026-08-19**, and this table said otherwise. |
| `Lang: Original` | **30**, was 10 | The correction. The whole scale is Surround 10, x264 10, x265 20, AV1 30, Original 30 - so at 10 a VO-only release scored 20 against a floor of 30 and **Silent Hill: Revelation 3D returned 124 releases and approved zero**. At 30 an identifiable-VO release clears the bar alone; one with no language information (score 0) still does not. |
| `Lang: Original + French` | **500** | Dominates every other format, so a French-carrying release always outranks a VO-only one. |
| `cutoffFormatScore` | **500** | Satisfied *only* by French. Reaching it is what makes Radarr stop searching. |
| `Rejected: 3D` | **-10000** | `3D`/`SBS`/`OU` in the release title. |

It was `cutoffFormatScore: 300`, which required `Global: Best` - AV1 **and** surround **and**
Original **and** French. That is effectively unobtainable, so nothing ever satisfied the cutoff and
every monitored film would have been searched for upgrades for ever.

**Radarr scores an existing FILE from its stored `sceneName`, not the renamed filename.** That is
what makes this work: the eight Harry Potter films are renamed to `Title (Year).mkv` with no
language markers, yet they score **820** because Radarr still holds
`...MULTI.1080p.BluRay.REMUX...`. They are at cutoff and inert. The Hobbit files score 50, and
*Battle of the Five Armies* scores **-9150** because the 3D penalty applies to existing files too -
which is exactly what let a 7.7 GB 2D release replace a 38.3 GB 3D one that Radarr had recorded as
`Bluray-2160p` (it is 3840x1080 side-by-side, so it looks like 4K by width).

**Check `/api/v3/moviefile`, not `/api/v3/movie`.** The movie list endpoint returns the nested
`movieFile` *without* `customFormatScore`, so every film reads `None` and looks below cutoff.

## Downloads are hardlinked, so the "source" usually still exists

`copyUsingHardlinks: true` means `library/queued/...` and `downloads/...` are the **same inode**
(`stat` shows `links=2`). Two consequences worth knowing before reaching for a re-download:

- The 130 GB in `queued/` costs nothing on top of `downloads/`, and Tdarr deleting the queued path
  leaves the torrent seeding untouched.
- **A film the pipeline damaged can usually be restored locally.** Five films lost their French dub
  to the old flow and had their queued copies deleted - but the original `MULTI` remuxes were still
  seeding, so `os.link()` put them back for 0 bytes and no bandwidth. **Look in `downloads/` before
  re-downloading anything.**

## The seeding policy, and the one part qBittorrent cannot express

**Seed for at least 72 hours, then stop at ratio 1.5 or one week, whichever comes first.** Since
2026-08-18 that is enforced by `bin/apply-seeding-policy.py` on `home-server-seeding.timer`, hourly.

**Deletion is still Radarr's and Sonarr's**, and the script deletes nothing. Both run with
`removeCompletedDownloads`, which removes the torrent *and its files* once the client reports it
done seeding - so the whole policy is expressed by deciding when a torrent is allowed to **stop**.
That split keeps deletion with the two applications that know whether a file was ever imported.

**They still track torrents imported months ago**, which is easy to conclude the opposite of. Radarr's
queue endpoint lists only what is downloading or awaiting import, so a seeding torrent looks
forgotten - but `/api/v3/history?downloadId=<hash>` still holds `grabbed` and `downloadFolderImported`
for a film grabbed in November 2025, and it was duly reaped. **Check history, not the queue.**

**The floor is the half that needs code, because every share limit qBittorrent has is a MAXIMUM.**
There is no minimum-seed-time setting anywhere in it, so a floor can only be enforced by withholding
the limits until a torrent has earned them. It binds in exactly one case - a torrent reaching ratio
1.5 in under three days - since the seven-day limit can never fire before 72 hours.

**THE GLOBAL LIMITS MUST STAY OFF, and that is the load-bearing part.** A per-torrent limit of `-2`
means "use the global one", and a new torrent starts at `-2` - so a global ratio limit reaps it hours
into its life with the script none the wiser and the floor silently gone. The script re-asserts
`max_ratio_enabled=false` every run rather than trusting the UI, and pins held torrents to an
explicit `-1` rather than leaving them at `-2`, which is only as safe as the setting it defers to.
`seeding.timer_enabled` and `seeding.run_age` are what prove the script is still running.

**`shareLimitAction` IS A STRING THAT SILENTLY ACCEPTS THE INTEGER.** qBittorrent 5 made it a
required parameter of `setShareLimits`, and `shareLimitAction=0` and `=3` **both answer 200 and both
store `Default`** - so the spelling matching qBittorrent's own enum is accepted, ignored, and
indistinguishable from success. Only `Stop` stores `Stop`. The only way to tell is to write the value
and read `share_limit_action` back out of `torrents/info`; the status code cannot. It is set to
`Stop` rather than `Default` for the same reason the limits are `-1` rather than `-2`: `Default`
defers to the global action, and a global `RemoveWithContent` would have qBittorrent delete files
behind Radarr.

**It fails in the safe direction.** A stopped timer means no torrent is ever promoted past the floor,
so nothing stops and nothing is deleted - the disk grows rather than the tracker account being spent.
Every check in the `Seeding policy` section is therefore WARN or PASS, never FAIL, for the reason the
Logs and Metrics sections give.

**Applying it reclaimed 214 GB on the first run** (`downloads/` 445 -> 231 GB, the volume 14% -> 11%),
because eight torrents had been seeding 13-39 days at **ratio 0** - the Harry Potter and Hobbit films
whose data had been rewritten in place, so they could never reach a limit and could never be cleaned
up. That is the space cost of the `mkvpropedit` damage, and it had no expiry.
