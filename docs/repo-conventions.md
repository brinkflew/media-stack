# Repository conventions

Lifted whole from `CLAUDE.md` on 2026-08-19. Nothing here was rewritten.

## `config/` is ignored wholesale, and `apps/` is why it can be

Everything under `config/` is **runtime state on the server** - application databases, Jellyfin
metadata, Caddy's certificates and ACME account, Pocket ID's passkey records. It is not in git.
Treat it as precious: it is the one thing here that cannot be rebuilt from this repository, which
is what `docs/backups.md` exists for.

**`.gitignore` is a single `config/` rule, and adding an exception to it is the wrong move.** It
used to carry a four-rule un-ignore chain (`config/*`, `!config/sonarr/`, `config/sonarr/*`,
`!config/sonarr/scripts/`) because git will not descend into an ignored directory to find an
exception inside it. All of that plumbing existed to track one 9-line script.

**A file that has to reach a container's config tree goes in `apps/<service>/` and is copied in by
an `ExecStartPre=` on that service's quadlet.** That is the same contract Tdarr's plugin always
had, now used for all of them:

| Tracked at | Lands at | How |
|---|---|---|
| `apps/caddy/` | `/etc/caddy` | bind-mounted read-only, as a directory |
| `apps/tdarr/plugins/` | `config/tdarr/server/Tdarr/Plugins/Local/` | `cp -a` |
| `apps/sonarr/scripts/` | `config/sonarr/scripts/` | `cp -a` |
| `apps/jellyfin/custom.css` | `config/jellyfin/branding.xml` | `bin/render-jellyfin-branding.py` |
| `apps/jellyfin/encoding.conf` | `config/jellyfin/encoding.xml` | `bin/render-jellyfin-encoding.py` |
| `apps/tdarr/flows/` | nowhere - **a record, not a deployment** | by hand; see that directory's README |

**Two things are tracked that nothing deploys, and the distinction matters.** `apps/tdarr/flows/`
holds an export of `avsOnePass1`; Tdarr has no import-from-disk mechanism, so the flow that actually
runs lives in its SQLite database and is edited in Tdarr's own flow editor. It is tracked so a flow
is reviewable and diffable at all - it decides what happens to every file in the library and was
previously recoverable from nothing but a backup of gitignored state. **Re-export it after any
edit**, or the copy in git silently becomes fiction.

**Jellyfin's `encoding.xml` came under the contract on 2026-08-15, and only in part.**
`apps/jellyfin/encoding.conf` names the elements that are decisions rather than defaults - the
keyframe-extraction extension list, throttling, the hardware-decode codec list - and
`bin/render-jellyfin-encoding.py` writes **only those**, never creating the document. That
restriction is the design, not laziness: `encoding.xml` has ~50 elements (tonemapping, VAAPI
device, CRF targets, deinterlacing) that are genuinely Jellyfin's to own, and authoring it from a
handful of tracked keys would reset every one of them by omission. **A list element must be declared
`Element[] = a,b,c`**, because an emptied list is written `<Foo />` and cannot be told from a scalar
by inspection - which is precisely the state the renderer exists to repair.

**`system.xml` and `network.xml` are still outside it**, and they hold real decisions - whether
trickplay uses the GPU, which proxies are trusted - so a `git grep` does not find them and a restore
brings back whatever was there. Treat them the way the Sonarr download-client settings are treated:
check them through the API rather than assuming.

**Git is authoritative, so editing the copy on the server is pointless** - it is overwritten on the
next start. Two consequences that are easy to be surprised by:

- **A Custom CSS edit made in Jellyfin's own UI reverts.** It survives until the next restart, and
  `podman-auto-update` restarts Jellyfin nightly, so it will look like it worked and quietly undo
  itself overnight. Edit `apps/jellyfin/custom.css`.
- **That CSS is VENDORED, and two of its stylesheets were deleted on purpose.** It used to be 16
  `@import` URLs into `CTalvio/Ultrachromic` at HEAD - an unpinned dependency on someone else's
  repository, on a page behind sign-on, plus 16 render-blocking fetches before first paint. It is
  inlined now (37 KB, ASCII, one remaining `@import` for a Google Font, which **must stay on the
  first line** - CSS ignores an `@import` that follows any rule, so moving it silently drops the
  font). `effects/glassy.css` and `effects/pan-animation.css` were **not** inlined: the first put
  `will-change: backdrop-filter` on 11 selectors including `.indicator` and `.cardOverlayButtonIcon`,
  which are on *every card*, so a 100-card page became 100+ composited layers each re-sampling what
  was behind it; the second ran an infinite `backgroundScroll` animation on the full-viewport
  backdrop, so it was never static. Together they re-blurred a moving full-screen image every frame
  and re-sampled it through a hundred layers, which is what made the UI "barely usable" while every
  other app was fine. **Do not add them back.** One narrow `backdrop-filter` survives on the three
  `.itemProgressBar` selectors; it is the next thing to remove if scrolling still stutters.
- **Sonarr's script path is recorded in `sonarr.db`, not here.** The "Clean Anime Extra Files"
  Custom Script connection stores `/config/scripts/anime-extra-files.sh`. Where the file lives in
  git is free; where it lands in the container is not, and a mismatch fails silently because that
  connection only fires on import.

## Editing this repository

There is still no build, no lint in the compiler sense and no test suite. What exists is
`bin/lint-repo.sh`, which asserts the four conventions nothing else enforces: every tracked text
file is ASCII, every script in `bin/` is executable, the shell passes shellcheck, and the quadlets
generate.

**The shellcheck leg SKIPS rather than FAILS when shellcheck is absent, and it had therefore never
run.** It was installed on neither machine until 2026-08-14, so the linter reported `all checks
passed` across 2,224 lines of shell it had not looked at - the exact shape of the problem this
repository keeps rediscovering, where a check that does nothing is indistinguishable from one that
works. The skip is still correct, because `/usr` is read-only on the server and the script has to
stay runnable there; the fix is that `bin/README.md` now names shellcheck as a workstation
prerequisite and says how to install it. The first real run found 18 issues, all of them minor.

**Prose and output here are ASCII, and that is checked rather than hoped for.** 402 non-ASCII
characters had accumulated by 2026-08-14 - em dashes, box drawing, arrows, a vulgar fraction. They
arrive by copy-paste, they are invisible in review, and in the shell scripts they end up inside
`printf` format strings that a terminal may not render. Use `-` for a dash, `->` for an arrow,
`>=` for a comparison, `x` for a multiplication sign.

**`.vscode/` is tracked**, and it exists because all 26 quadlets and 6 plain units otherwise open as
unhighlighted text. `hangxingliu.vscode-systemd-support` is the one that matters - its `systemd-conf`
language claims `.container`, `.volume`, `.pod`, `.build`, `.network`, `.service` and `.timer`, which
is every unit type here. Butane and Ignition have no extension in Open VSX at all, so `*.bu` is
associated with YAML and `*.ign` with JSON instead.

**No SOPS extension, deliberately.** The transparent-decrypt ones add a path by which a plaintext
secret can be written to disk in a public repository. `sops secrets/env.sops.env` opens it in
`$EDITOR` and re-encrypts on save without plaintext ever touching the disk.
