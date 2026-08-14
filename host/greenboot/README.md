# greenboot

Automatic rollback of a bad OS deployment. This machine has no console and no BMC, so a
deployment that boots without sshd is a car journey; greenboot is what makes an unattended
reboot defensible, and roadmap item 2 depends on it.

`bin/verify-host.sh --greenboot` is the health check. It asserts host-level state only and
deliberately never looks at the eighteen containers - **greenboot has no ordering against
the user manager at all**, so the stack is still starting when the verdict is rendered.

## What is installed where

Individual files are symlinked, as in `host/systemd/`, so `git pull` deploys a change with
no copy step. Nothing here is picked up automatically; each link is made once.

| Tracked here | Installed at | What it is |
|---|---|---|
| `40-media-stack.sh` | `/etc/greenboot/check/required.d/40-media-stack.sh` | the check wrapper, **symlinked** |
| `50-record-red-boot.sh` | `/etc/greenboot/red.d/50-record-red-boot.sh` | the loop-breaker, **symlinked** |
| (inline in `ucore.bu`) | `/etc/systemd/system/greenboot-healthcheck.service.d/10-media-stack.conf` | ordering and timeout, **a real file** |
| `custom.cfg` | `/boot/grub2/custom.cfg` | GRUB boot counting, **copied not symlinked** |

```bash
sudo rpm-ostree install greenboot      # NOT greenboot-default-health-checks - see below
sudo ln -sf /var/media-stack/host/greenboot/40-media-stack.sh \
            /etc/greenboot/check/wanted.d/40-media-stack.sh
# the drop-in is an ordinary file - see host/butane/ucore.bu for its contents
sudo systemctl daemon-reload
sudo systemctl enable greenboot-healthcheck.service
```

**`rpm-ostree install` does not enable anything.** FCOS ships `99-default-disable.preset`,
so every greenboot unit lands disabled and **nothing runs at boot** - which looks exactly like
a host that has never had a bad deployment. This was measured, not assumed: the first boot
after layering ran no check at all. `bin/verify-host.sh` now asserts the unit is enabled.

## SELinux decides what may be a symlink, and it fails silently

**PID 1 cannot read or execute anything under `/var/media-stack`.** SELinux is Enforcing and the
checkout is `var_t`. So a *system* unit, or a drop-in for one, symlinked into this repository is
silently ignored - and it is convincingly silent:

| | symlinked into the checkout |
|---|---|
| `systemctl cat` | prints the drop-in, because the client reads it unconfined |
| `systemctl show -p After` | **none of the ordering is there** |
| `systemctl is-enabled` | `Access denied` |
| a unit whose `ExecStart=` points there | `status=203/EXEC`, `Permission denied` |
| audit log | **no AVC** |

The check script next door *is* a symlink, and correctly so. greenboot execs it itself, from
`/usr/libexec/greenboot/greenboot`, so it runs as `unconfined_service_t` and may read and exec
the checkout freely. The rule:

> Whatever **systemd** launches or parses must live somewhere properly labelled. Anything a
> already-running process then reaches is free.

This is why the user-scope quadlets in `stacks/` can be whole-directory symlinks and host-level
system units cannot. System drop-ins therefore ship as inline `files:` entries in
`host/butane/ucore.bu`, the same way `/etc/systemd/system/user@.service.d/10-delegate-io.conf`
always has.

`verify-host.sh` asserts the drop-in **by its effect** - that `systemctl show -p After` actually
contains the ordering - rather than by the file existing, because the file existed the whole time
it was doing nothing.

Layering one package is a deliberate exception to "avoid host-level package dependencies".
It is the only way to get greenboot on uCore, which does not ship it, and the cost is that
a future rebase can fail on dependency solving. That failure is not silent:
`bin/verify-host.sh` asserts the last update run's **exit status**, not merely its age.

## Three things that are not obvious

**Fedora 44 ships greenboot-rs 0.16, not the shell version every blog post describes.**
`redboot.target`, `greenboot-task-runner`, `greenboot-grub2-set-success` and
`greenboot-rpm-ostree-grub2-check-fallback` **do not exist**. There are three units:
`greenboot-healthcheck.service`, `greenboot-set-rollback-trigger.service` and
`greenboot-success.target`. The healthcheck unit carries `RefuseManualStart=yes`, so it
cannot be started by hand - to run the checks, call the binary:

```bash
sudo /usr/libexec/greenboot/greenboot health-check
journalctl -b -u greenboot-healthcheck -o cat
```

**`greenboot-default-health-checks` is deliberately not installed.** It adds a DNS check and
a watchdog check as *required*, either of which can red a boot for reasons that have nothing
to do with the deployment - and a red boot here reverts the OS. The base package already
creates the check directories, so one package is enough. Note that greenboot treats a
missing `required.d` as a hard error, so the directory must exist even while empty.

**GRUB boot counting does not work out of the box on FCOS, and its absence is silent.**
greenboot installs its snippet to `/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg`,
but `/boot/grub2/grub.cfg` is generated **once** by bootupd at install time and is not
regenerated by package layering. So greenboot arms a `boot_counter` that nothing counts
down: the checks run, the journal looks right, and rollback quietly cannot happen. That is
why `custom.cfg` exists - the generated grub.cfg already ends with

```
### BEGIN 41_custom.cfg ###
if [ -f $prefix/custom.cfg ]; then
  source $prefix/custom.cfg
fi
```

which is sourced *after* `10_blscfg.cfg`, so `set default=1` resolves against loaded BLS
entries. It lives on `/boot` rather than in `/usr`, so layering and OS updates leave it
alone. `insmod increment` works here: the module is compiled into this box's `grubx64.efi`
(it is UEFI - the `i386-pc/increment.mod` on disk is for the BIOS build and is irrelevant).

**It is copied, not symlinked.** GRUB reads it before any filesystem but `/boot` exists.

## wanted.d or required.d - the safety switch

| Directory | A failing check |
|---|---|
| `check/wanted.d/` | is logged, and nothing else |
| `check/required.d/` | reds the boot, and the deployment is rolled back |

**Phase 1 uses `wanted.d`, and additionally has no `custom.cfg`.** Both halves are needed
for observe-only: without the GRUB snippet no counter ever reaches its limit, so the
rollback path is unreachable no matter what the checks say. `wanted.d` on top of that keeps
`greenboot-healthcheck.service` out of `failed`, which matters because `verify-host.sh`
asserts that no system unit has failed and would otherwise report its own check as a fault.

Moving the symlink to `required.d` and adding `custom.cfg` is what arms it. Do not do that
without running the negative control - a check that cannot fail is decorative:

```bash
printf '#!/bin/sh\nexit 1\n' | sudo tee /etc/greenboot/check/required.d/99-prove-it.sh
sudo chmod +x /etc/greenboot/check/required.d/99-prove-it.sh
# reboot, on a day you can reach the machine, with two deployments present.
# GRUB should count down and revert. Then REMOVE the file.
sudo grub2-editenv /boot/grub2/grubenv list      # boot_counter, boot_success
```

## The verdict, and where to read it

`/var/lib/media-stack/boot-state`, written by the wrapper on every boot and surfaced hourly
in the MOTD by `bin/verify-host.sh`. `ExecMainExitTimestamp` is runtime state that a reboot
wipes, which is useless when the subject is the reboot.

```
greenboot_result=green|red|timeout|missing
greenboot_checked_at=2026-08-14T09:53:11Z
booted_version=44.20260720.3.1
booted_checksum=25319705c9ff
rollback_at=...        # set by red.d, cleared by a human
```

`timeout` and `missing` are recorded as **inconclusive and exit 0**. A rollback cannot fix a
missing checkout or a slow `rpm-ostreed`, and a health check that reverts the OS for either
would be doing harm confidently. Only a confirmed FAIL is allowed to mean "bad deployment" -
the same rule the off-site policy probe follows.

## greenboot does not reboot on a red boot, and that is the whole shape of it

**Measured on the installed 0.16, and it is not what the name suggests.** There is no
`OnFailure=` on `greenboot-healthcheck.service`, no `redboot.target`, and nothing depends on
`boot-complete.target` except `greenboot-success.target`. So an unhealthy boot leaves the
machine **up, on the bad deployment, with `boot_success=0`** - and then waits.

The counter only moves when a boot happens, because GRUB is what decrements it. So:

```
boot 1   new deployment. ConditionNeedsUpdate fires, boot_counter=3 is armed.
         check fails -> red.d records red_boot_at. NOTHING REBOOTS.
boot 2   (only if something reboots)  GRUB 3 -> 2
boot 3                                GRUB 2 -> 1
boot 4                                GRUB 1 -> 0, sets default=1 and boot_counter=-1
         -> the previous deployment boots, greenboot notices the fallback and makes it
            permanent with `rpm-ostree rollback`
```

**So greenboot on its own gives detection, not recovery.** Recovery needs something to reboot,
and that is a deliberate decision rather than a default - a reboot-on-red is bounded by the
counter, but it is still a machine with no console rebooting itself because a check failed.

`greenboot-set-rollback-trigger.service` is worth reading for the same reason: it runs
`ExecStart` **at boot**, not `ExecStop` at shutdown as most write-ups claim, and it is gated by
`ConditionNeedsUpdate=|/etc`. That is a useful safety property - the counter is only ever armed
on the first boot into a **new** deployment, which is exactly when a rollback target exists. It
is why arming this with a single deployment on disk cannot strand the machine.

## Two traps worth knowing before arming this

**A rollback with nothing else changed re-applies the same image.** FCOS's own documentation
flags it: after reverting, the updater stages the same digest again, so an armed greenboot
plus an unattended reboot is a loop that reverts and re-applies a bad deployment nightly.
The `red.d` hook writes `rollback_at`, and `bin/reboot-when-staged.sh` refuses to reboot
while that marker is unacknowledged.

**Rollback needs somewhere to roll back to.** `/boot` holds exactly two kernel slots and
cannot be grown. That is enough, because slots are counted per distinct kernel+initramfs and
rpm-ostree drops the rollback when it stages the next update - but a host that has just run
`rpm-ostree cleanup -r` has **one** deployment and no rollback target at all. Check with
`rpm-ostree status` before expecting greenboot to be able to do anything.
