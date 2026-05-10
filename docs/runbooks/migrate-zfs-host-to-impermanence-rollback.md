# Migrate an existing ZFS host to impermanence rollback

## Background

The repo's NixOS hosts use ZFS with a `<pool>/local/root@empty` snapshot for impermanence-style root rollback. `scheelite` defines a `boot.initrd.systemd.services.rollback-root` service that actually performs the rollback at boot. `malachite`, `argentite`, and `cassiterite` originally lacked this service — their `/` accumulated state across boots, which eventually broke impermanence on a rebuild (a regenerated `/etc/machine-id` blocked the bind-mount).

The commits on branch `treewide-impermenance-udpate` (`2a168e1`, `c30778f`, `620825b`) added the rollback service plus an expanded persistence list to all three hosts. The list (see `nixos-configurations/<host>/impermanence.nix`) covers ssh host keys, full `/var/lib/systemd`, NetworkManager, bluetooth, fwupd, upower, fprint, AccountsService, sddm, power-profiles-daemon, udisks2, `/var/lib/private`, and CUPS mutable subpaths.

**First deploy of this change on each existing host requires hands-on recovery**, because:

1. **File-level impermanence binds fail loudly.** During `nixos-rebuild switch` activation, impermanence's `mount-file` script refuses to bind-mount over a non-empty existing file (`"A file already exists at /etc/machine-id!"`). The new generation is still installed and the bootloader updated, but you must pre-seed `/persist` with the right identity files or the post-rollback boot regenerates them (machine-id flip, ssh fingerprint change).
2. **Directory-level binds fail silently.** Impermanence happily bind-mounts an empty `/persist/var/lib/<x>` over a populated `/var/lib/<x>` during activation. The underlying data on the `/` dataset is still there, but the rollback at next boot will wipe it. Capture it via a ZFS snapshot and rsync into `/persist` before rebooting.

This runbook is the procedure that worked end-to-end on `malachite` on 2026-05-10. Run it for each remaining host (`argentite`, `cassiterite`, plus any future host going from "no rollback, accumulated state" to "rollback + impermanence").

## When this runbook does NOT apply

- **Fresh installs.** There's no accumulated state to recover. Seed `/persist/etc/machine-id` and `/persist/etc/ssh/ssh_host_*` if you want stable identity from boot 1, then `nixos-rebuild switch`. No snapshot dance needed.
- **Hosts already running with rollback** (e.g. `scheelite`). Adding more persisted paths to such a host doesn't require this runbook — the targets are already empty/bind-mounted, so impermanence's services succeed on first activation.

## Prerequisites

- The branch with rollback-root + the expanded persistence list is merged or checked out on the target host.
- You're physically/remotely on the host being migrated and have sudo.
- The host's `/persist` dataset is healthy and writable.
- Identify the ZFS pool name (`zpool list` or check `nixos-configurations/<host>/disko.nix`). `malachite`/`argentite`/`cassiterite` use `zroot`; `scheelite` uses `scheelite-root`. Substitute `<POOL>` below.

## Procedure

### 1. Seed `/persist` with identity files

```sh
sudo cp /etc/machine-id /persist/etc/machine-id
sudo install -d -m 0755 /persist/etc/ssh
sudo cp -p /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub /persist/etc/ssh/
sudo ls -la /persist/etc/machine-id /persist/etc/ssh/
```

Verify: `/persist/etc/machine-id` is 33 bytes; ed25519 private key is 600 perms; rsa private key is 600 perms; `.pub` files are 644; all `root:root`.

### 2. Deploy the new config

```sh
sudo nixos-rebuild switch --flake .#<host>
```

**Expect non-zero exit (status 4) with output like:**

```
Warning: Source directory '/persist/var/lib/...' does not exist; it will be created for you...
A file already exists at /etc/machine-id!
A file already exists at /etc/ssh/ssh_host_ed25519_key!
A file already exists at /var/lib/logrotate.status!
A file already exists at /var/lib/cups/subscriptions.conf!
Activation script snippet 'persist-files' failed (1)
warning: the following units failed: persist-persist-etc-machine\x2did.service, ...
```

This is expected. Verify the new generation was installed despite the activation hiccup:

```sh
readlink /run/current-system
sudo bootctl list | head -10
```

`/run/current-system` should point to the just-built derivation, and `bootctl list` should show the new generation marked `(default)`.

### 3. Recover hidden directory state via ZFS snapshot

ZFS snapshots capture the dataset content, not the live bind-mount overlay — so a snapshot taken now still sees the underlying populated `/var/lib/<x>` data that the bind mounts are masking.

```sh
sudo zfs snapshot <POOL>/local/root@premigration
sudo ls /.zfs/snapshot/premigration/var/lib/ | head
```

Then rsync each populated directory from the snapshot into `/persist`. **Emit each command on its own line when you give these to the user** — pasting multi-line `for` loops through Claude Code's output formatting causes fish to silently split the iterable, leaving directories un-synced.

```sh
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/bluetooth/ /persist/var/lib/bluetooth/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/NetworkManager/ /persist/var/lib/NetworkManager/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/upower/ /persist/var/lib/upower/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/fwupd/ /persist/var/lib/fwupd/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/lastlog/ /persist/var/lib/lastlog/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/AccountsService/ /persist/var/lib/AccountsService/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/sddm/ /persist/var/lib/sddm/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/power-profiles-daemon/ /persist/var/lib/power-profiles-daemon/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/udisks2/ /persist/var/lib/udisks2/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/private/ /persist/var/lib/private/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/fprint/ /persist/var/lib/fprint/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/cups/ /persist/var/lib/cups/
sudo rsync -aHAX --info=stats0 /.zfs/snapshot/premigration/var/lib/systemd/ /persist/var/lib/systemd/
```

The `/var/lib/cups` rsync pulls in nix-store symlinks pointing at the *pre-migration* generation's cups package. That's fine: cupsd's `ExecStartPre` removes all symlinks under `/var/lib/cups` and recreates them from the current store path each time it starts, so these get refreshed on first boot after rollback.

If the persist list in `impermanence.nix` has been expanded beyond what this runbook documents, also rsync any new paths from the snapshot.

### 4. Verify recovery before destroying the snapshot

```sh
sudo ls /persist/var/lib/bluetooth /persist/var/lib/NetworkManager /persist/var/lib/systemd
sudo ls /persist/var/lib/fwupd /persist/var/lib/upower /persist/var/lib/AccountsService /persist/var/lib/systemd/backlight /persist/var/lib/systemd/timers /persist/var/lib/systemd/timesync /persist/var/lib/sddm
```

Expected content:
- `bluetooth/`: subdirs named after paired device MAC addresses (skip if no bluetooth devices were paired).
- `NetworkManager/`: `secret_key`, `seen-bssids`, `timestamps`, `NetworkManager.state`, plus per-connection `*.lease` files.
- `systemd/`: `backlight`, `catalog`, `coredump`, `ephemeral-trees`, `linger`, `random-seed`, `rfkill`, `timers`, `timesync`.
- `fwupd/`: `pending.db`, `gnupg/`, `metadata/`, `pki/`.
- `upower/`: `history-*.dat` files (battery history).
- `AccountsService/`: `users/`, `icons/`.

If any directory you expected to have data is empty, **do not destroy the snapshot or reboot** — investigate first. The snapshot is the only path back to the pre-bind-mount state.

When you've confirmed each path has its expected data:

```sh
sudo zfs destroy <POOL>/local/root@premigration
sudo zfs list -t snapshot <POOL>/local/root
```

Only `@empty` should remain.

### 5. Reboot

```sh
sudo reboot
```

The initrd `rollback-root` service runs before stage 2 init mounts the root and wipes `/` to the `@empty` snapshot. NixOS activation then regenerates `/etc` fresh, and impermanence's persist-X services bind-mount `/persist` files/dirs over the now-empty targets without conflict.

### 6. Post-reboot verification

```sh
journalctl -b -u rollback-root.service
findmnt /etc/machine-id /etc/ssh/ssh_host_ed25519_key /var/lib/bluetooth
systemctl --failed
cat /etc/machine-id
```

Expected:
- `rollback-root` journal shows `rollback of <pool> complete`.
- `findmnt` shows bind mounts on each path queried.
- No failed units (or only pre-existing unrelated ones).
- `/etc/machine-id` matches the contents of `/persist/etc/machine-id`.
- SSH client connections from your laptop don't trigger a host-key-changed warning.

## Known gotchas

- **Don't reboot before step 4 verification passes.** Once the system reboots and rollback fires, the snapshot is gone (you destroyed it) and the underlying `/` state is wiped. If you skipped a path in step 3, that path's pre-migration data is unrecoverable.
- **Fish + multi-line scripts.** Pasting a multi-line `for ... end` loop from Claude Code's chat into fish frequently splits at the soft-wrap, leaving the second half of the iterable as a separate command. Default to one command per line.
- **Per-host snapshot scope.** The recovery snapshot only covers the host you're on. If you migrate a host while logged in over SSH from a different host, the snapshot still has to be taken locally on the target.
- **Persist list drift.** This runbook documents the persist list as of the initial rollout. If `nixos-configurations/<host>/impermanence.nix` has gained new entries since, add corresponding rsync lines in step 3.
- **Atomic-rename-incompatible files.** Do not add a file to the persist `files = [ ... ]` list if the application that owns it writes via `rename(tmp, target)` (logrotate, pacman/dpkg-style updaters, many config writers including CUPS). The kernel returns `EBUSY` on a `rename()` whose destination is a bind-mounted file, and a symlink target gets clobbered. `/var/lib/logrotate.status` was tried during initial rollout and removed in `4b4114d`/`91bb2ab`/`79f3f57` for this reason. If you need that kind of state persisted, either persist its parent *directory* (the rename happens inside a bind-mounted dir, which is fine) or reconfigure the app to write to a path inside an already-persisted dir.
- **Applications that prune their own state directory.** Some services run an `ExecStartPre` that removes files (typically symlinks) from the directory they expect to own. `cupsd` cleans all symlinks under `/var/lib/cups` on every start, then re-creates only the 5 nix-store-managed config symlinks. If you persist individual files under such a directory, impermanence's `auto` mode creates dangling symlinks for non-existing targets — which the service's pre-start then deletes. Persist the *parent directory* instead, so impermanence uses a bind mount and the service's pre-start operates on `/persist` contents. Initial rollout persisted `/var/lib/cups/{ppd,ssl,subscriptions.conf,printers.conf,classes.conf}` individually; changed to `/var/lib/cups` wholesale in `2671390`/`81e22cc`/`99fcdcd`.

## Related

- `nixos-configurations/<host>/impermanence.nix` — canonical persist list per host.
- `nixos-configurations/<host>/default.nix` — `boot.initrd.systemd.services.rollback-root` lives here.
- `nixos-configurations/scheelite/default.nix` — reference implementation of the rollback service.
- impermanence's `mount-file` script source: `nix-community/impermanence` on GitHub (look for `mount-file.bash`).
