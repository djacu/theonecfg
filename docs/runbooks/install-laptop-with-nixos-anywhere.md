# Install an encrypted, impermanence laptop with nixos-anywhere

Procedure for installing one of this repo's laptop hosts from argentite over
SSH, with the target booted from the NixOS minimal live ISO. All of them use
root rollback and impermanence; they differ in what the disk passphrase
unlocks:

- LUKS hosts (`ilmenite`): every partition except the ESP is a LUKS2
  container with `passwordFile = "/tmp/secret.key"` in `disko.nix`; the ZFS
  pool inside is not natively encrypted. One prompt at boot, shared by the
  containers through systemd's passphrase cache. These hosts run with
  `boot.zfs.forceImportRoot = false`.
- ZFS-native hosts (`malachite`, `cassiterite`): the pool has
  `keylocation = "file:///tmp/secret.key"` at create time and a zpool
  `postCreateHook` of `zfs set keylocation=prompt <pool>`.

First executed for `ilmenite` on 2026-10-03 (ZFS-native) and again for the
LUKS layout; see `docs/plans/active/ilmenite-hibernation.md`.

## Prerequisites

On the target:

1. Secure Boot off in firmware. The 26.05 ISO's boot loader is unsigned GRUB;
   with Secure Boot on, the stick is not listed as bootable.
1. Boot the NixOS minimal live ISO from a port on the laptop itself, not a
   hub. Wired network is simplest.
1. As the `nixos` user: `sudo passwd root` and set a throwaway password.
1. Note the address: `ip -4 -brief addr`.

On argentite, in the repo root on the branch that adds or changes the host,
with every new file tracked (`git add -N`) and
`nix build .#nixosConfigurations.<host>.config.system.build.toplevel` already
green.

## Procedure (fish, on argentite)

Replace `<host>`, `<ip>`, `<user>`, and `<pool>`. The live ISO has a fresh
host key on every boot, so talk to it without recording that key; the two
aliases below do what nixos-anywhere itself does:

```fish
alias isossh 'ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
alias isoscp 'scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
```

1. Confirm the disk id in the host's `disko.nix` exists on the target and is
   the intended disk:

   ```fish
   isossh root@<ip> 'ls -l /dev/disk/by-id/ | grep -v -- -part; lsblk -o NAME,SIZE,MODEL,SERIAL /dev/nvme0n1; modprobe zfs && zfs version'
   ```

   The `device` in `disko.nix` must appear in the listing and point at the
   NVMe shown by `lsblk`, and `zfs version` must print a version (the ZFS
   module is loaded on the ISO). Stop if either check fails.

1. Stage the passphrase and the identity files:

   ```fish
   set work (mktemp -d)
   read -s -P 'Disk passphrase: ' diskpass
   printf '%s\n' $diskpass > $work/disk.key
   set -e diskpass
   od -c $work/disk.key | tail -n 2
   install -d -m 0755 $work/extra/persist/etc/ssh
   ssh-keygen -q -t ed25519 -N '' -C <host> -f $work/extra/persist/etc/ssh/ssh_host_ed25519_key
   ssh-keygen -q -t rsa -b 4096 -N '' -C <host> -f $work/extra/persist/etc/ssh/ssh_host_rsa_key
   systemd-id128 new > $work/extra/persist/etc/machine-id
   chmod 0444 $work/extra/persist/etc/machine-id
   ssh-keygen -lf $work/extra/persist/etc/ssh/ssh_host_ed25519_key.pub
   cat $work/extra/persist/etc/machine-id
   ```

   The passphrase must be ASCII only; the initrd prompt uses the US keymap.
   ZFS-native hosts also need at least 8 characters (the OpenZFS minimum,
   checked only at `zpool create`, after the disk is partitioned).

   The `od` output must end with the passphrase's last character followed
   by a single `\n` and nothing else: no `\r`, no trailing space. Both
   consumers drop that newline. disko hands the file to `cryptsetup` as
   `$(cat ...)`, which strips trailing newlines, for `luksFormat` and for
   the open that follows alike; ZFS trims one newline when it reads a key
   file. Either way, the passphrase typed at the boot prompt is the file's
   content without the newline. Record the fingerprint and machine-id for
   the post-install check.

   The keys go under `persist/` because `/etc` on the root dataset is rolled
   back on every boot; `--copy-host-keys` would land them in the wrong place.

1. LUKS hosts only: give the installer the host's ZFS host id before the
   pool is created. The pool records the host id of the system that creates
   it, and these hosts import without `-f`, so the installer must carry the
   host's id. nixos-anywhere exports the pool at the end anyway, but that
   export runs with `|| true`; this makes a swallowed failure harmless.
   The ISO ships its own `/etc/hostid` as a symlink into its read-only
   store, so the link is removed and a real file put in its place:

   ```fish
   isoscp (nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.environment.etc.hostid.source) root@<ip>:/root/hostid
   isossh root@<ip> 'rm -f /etc/hostid && mv /root/hostid /etc/hostid && od -An -tx1 /etc/hostid'
   nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.environment.etc.hostid.source | xargs od -An -tx1
   ```

   The two `od` lines must be identical: the host id's bytes in reverse
   order, `4d a7 66 11` for ilmenite. The ZFS tools and the kernel module
   both read `/etc/hostid` on demand, so no reload is needed. Stop if the
   lines differ.

1. Install:

   ```fish
   read -s -P 'ISO root password: ' -x SSHPASS
   nix run .#nixos-anywhere -- \
     --env-password \
     --flake .#<host> \
     --target-host root@<ip> \
     --disk-encryption-keys /tmp/secret.key $work/disk.key \
     --extra-files $work/extra
   set -e SSHPASS
   ```

   nixos-anywhere sees `VARIANT_ID=installer` and skips kexec, uploads the
   key file, runs disko (destroy, format, mount), copies the closure built on
   argentite, untars the extra files into `/mnt`, runs `nixos-install`,
   unmounts, exports the pool, and reboots about six seconds after printing
   `Rebooting`. In the disko output look for, on LUKS hosts, one
   `luksFormat` per container and a `zpool create` line without
   `encryption=`; on ZFS-native hosts, the `zpool create` line and the
   hook's `zfs set keylocation=prompt`. Leave the stick in until the screen
   goes dark for the reboot: it is the live system's root, and the unmount
   and export still need it. Then pull it, or pick the NVMe entry in the
   firmware boot menu.

1. First boot, on the target. LUKS hosts: the initrd asks once,
   `Please enter passphrase for disk cryptswap` or `cryptzroot`, whichever
   unit asks first; the other container unlocks from the cached answer.
   ZFS-native hosts: `Enter key for <pool>`. Log in to Plasma with the
   password, before enrolling any fingerprint.

1. Apply home-manager on the target, from a checkout of the repo on the
   branch that was installed:

   ```fish
   nix run --inputs-from . home-manager-unstable -- switch --flake .#<host>-<user>
   ```

## Post-install checks (on the target)

Each line is a command and what it must show.

- `hostid` equals `nix eval --raw .#nixosConfigurations.<host>.config.networking.hostId`.
- `zpool status <pool>` shows `state: ONLINE`.
- LUKS hosts: `zfs get -H -o value encryption <pool>` prints `off`;
  `sudo cryptsetup status cryptswap` and `sudo cryptsetup status cryptzroot`
  both print `is active and is in use`, `type:    LUKS2`, and
  `flags:   discards no_read_workqueue no_write_workqueue`.
- ZFS-native hosts: `zfs get -H -o value keylocation <pool>` prints `prompt`.
- `swapon --show` lists one partition entry named `/dev/dm-N` (the mapper's
  kernel name, not the `/dev/mapper/` alias); on LUKS hosts
  `ls -l /dev/mapper/cryptswap` points at that same `dm-N` and the size is
  68G.
- LUKS hosts: `systemctl show -p Options dev-mapper-cryptswap.swap` prints
  `Options=discard=once`.
- `cat /proc/cmdline`: LUKS hosts contain `resume=/dev/mapper/cryptswap` and
  no `nohibernate`; ZFS-native hosts contain `nohibernate` and no `resume=`.
- `lsmod | grep -E '^(xe|framework_laptop|cros_ec_lpcs) '` lists all three.
- `cat /sys/class/power_supply/BAT1/charge_control_end_threshold` prints a number.
- `nix shell .#efibootmgr -c sudo efibootmgr` (efibootmgr is not installed on the host; `sudo` keeps `PATH`) shows `Linux Boot Manager` first in `BootOrder`. A reinstall leaves a second `Linux Boot Manager` entry pointing at the old ESP's partition id; delete it with `nix shell .#efibootmgr -c sudo efibootmgr -b <id> -B` after confirming its partition GUID is not the current ESP's (`lsblk -o NAME,PARTUUID /dev/nvme0n1`).
- `cat /etc/machine-id` equals the staged id; `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` equals the staged fingerprint.
- `systemctl --failed` prints `0 loaded units listed`.
- `fprintd-enroll` succeeds; afterwards `sudo -k; sudo true` accepts a finger.
- `fwupdmgr get-devices` lists the system firmware and the fingerprint reader.
- Speakers, headset jack, Wi-Fi, and Bluetooth each work once.

Optional: delete other stale firmware boot entries with
`nix shell .#efibootmgr -c sudo efibootmgr -b <id> -B`
after confirming each points at a partition that no longer exists.

## Cleanup (fish, on argentite)

Only after the post-install checks pass, since Rollback re-runs the install
step and needs the staged files:

```fish
rm -rf $work
```

Also drop the old host key the laptop had before a reinstall:
`ssh-keygen -R <host>` and `ssh-keygen -R <ip>` for every address it used.

## Rollback

The disk was blank, so a failed install loses nothing. Fix the configuration
and re-run the install step.

If the first boot cannot import the pool: on LUKS hosts, first try
`zfs_force=1` once, typed into the boot entry from the systemd-boot editor
(press `e`), which imports with `-f` for that boot only. If that is not
enough, boot the stick and repair from there, in this order.

First, on a host that can hibernate, make sure no hibernation image is
waiting on its swap. Importing the pool elsewhere while an image exists, and
then letting the next normal boot resume that image, corrupts the pool. The
same applies to booting such a host with `noresume`: never do it while an
image may exist. Unlock the swap container and overwrite the swap header,
which drops any image:

```sh
cryptsetup open /dev/disk/by-partlabel/disk-disk1-swap cryptswap
mkswap /dev/mapper/cryptswap
```

Then import without mounting (`-N`: the datasets' mountpoints are `/`,
`/nix`, and `/home`, and a mounting import would cover the live system's own
directories), export, and reboot:

```sh
cryptsetup open /dev/disk/by-partlabel/disk-disk1-zfs cryptzroot
zpool import -f -N <pool>
zpool export <pool>
```

ZFS-native hosts skip the `cryptsetup` lines and use the same `-N` import.
