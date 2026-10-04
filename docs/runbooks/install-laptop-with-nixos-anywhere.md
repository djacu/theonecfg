# Install a ZFS-encrypted, impermanence laptop with nixos-anywhere

Procedure for installing one of this repo's laptop hosts (ZFS native
encryption with a passphrase prompt, root rollback, impermanence) from
argentite over SSH, with the target booted from the NixOS minimal live ISO.
First executed for `ilmenite` on 2026-10-03.

The host's `disko.nix` must use `keylocation = "file:///tmp/secret.key"` and
a zpool `postCreateHook` of `zfs set keylocation=prompt <pool>`. See
`nixos-configurations/ilmenite/disko.nix`.

## Prerequisites

On the target:

1. Secure Boot off in firmware. The 26.05 ISO's boot loader is unsigned GRUB;
   with Secure Boot on, the stick is not listed as bootable.
1. Boot the NixOS minimal live ISO. Wired network is simplest.
1. As the `nixos` user: `sudo passwd root` and set a throwaway password.
1. Note the address: `ip -4 -brief addr`.

On argentite, in the repo root on the branch that adds the host, with every
new file tracked (`git add -N`) and `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
already green.

## Procedure (fish, on argentite)

Replace `<host>` and `<ip>`.

1. Confirm the disk id in the host's `disko.nix` exists on the target and is
   the intended disk:

   ```fish
   ssh root@<ip> 'ls -l /dev/disk/by-id/ | grep -v -- -part; lsblk -o NAME,SIZE,MODEL,SERIAL /dev/nvme0n1'
   ```

   The `device` in `disko.nix` must appear in the listing and point at the
   NVMe shown by `lsblk`. Stop if it does not.

1. Stage the passphrase and the identity files:

   ```fish
   set work (mktemp -d)
   read -s -P 'ZFS passphrase: ' zfspass
   printf '%s\n' $zfspass > $work/zfs.key
   set -e zfspass
   od -c $work/zfs.key | tail -n 2
   install -d -m 0755 $work/extra/persist/etc/ssh
   ssh-keygen -q -t ed25519 -N '' -C <host> -f $work/extra/persist/etc/ssh/ssh_host_ed25519_key
   ssh-keygen -q -t rsa -b 4096 -N '' -C <host> -f $work/extra/persist/etc/ssh/ssh_host_rsa_key
   systemd-id128 new > $work/extra/persist/etc/machine-id
   chmod 0444 $work/extra/persist/etc/machine-id
   ssh-keygen -lf $work/extra/persist/etc/ssh/ssh_host_ed25519_key.pub
   cat $work/extra/persist/etc/machine-id
   ```

   The `od` output must end with the passphrase's last character followed
   by a single `\n` and nothing else. ZFS trims that one newline when it
   reads the file, so the same passphrase typed at the initrd prompt
   unlocks the pool. Record the fingerprint and machine-id for the
   post-install check.

   The keys go under `persist/` because `/etc` on the root dataset is rolled
   back on every boot; `--copy-host-keys` would land them in the wrong place.

1. Install:

   ```fish
   set -x SSHPASS <root password set on the live ISO>
   nix run .#nixos-anywhere -- \
     --env-password \
     --flake .#<host> \
     --target-host root@<ip> \
     --disk-encryption-keys /tmp/secret.key $work/zfs.key \
     --extra-files $work/extra
   set -e SSHPASS
   ```

   nixos-anywhere sees `VARIANT_ID=installer` and skips kexec, uploads the
   key file, runs disko (destroy, format, mount), untars the extra files
   into `/mnt`, copies the closure built on argentite, runs `nixos-install`,
   exports the pool, and reboots. In the disko output look for the
   `zpool create` line and the hook's `zfs set keylocation=prompt`.

1. First boot, on the target: the initrd asks `Enter key for <pool>`. Log in
   to Plasma with the password, before enrolling any fingerprint.

1. Apply home-manager on the target, from a checkout of the repo:

   ```fish
   nix run --inputs-from . home-manager-unstable -- switch --flake .#<host>-<user>
   ```

## Post-install checks (on the target)

Each line is a command and what it must show.

- `hostid` equals `nix eval --raw .#nixosConfigurations.<host>.config.networking.hostId`.
- `zpool status <pool>` shows `state: ONLINE`; `zfs get -H -o value keylocation <pool>` prints `prompt`.
- `swapon --show` lists one `/dev/mapper/` device; `cat /proc/cmdline` contains `nohibernate` and no `resume=`.
- `lsmod | grep -E '^(xe|framework_laptop|cros_ec_lpcs) '` lists all three.
- `cat /sys/class/power_supply/BAT1/charge_control_end_threshold` prints a number.
- `nix shell .#efibootmgr -c sudo efibootmgr` (efibootmgr is not installed on the host; `sudo` keeps `PATH`) shows `Linux Boot Manager` first in `BootOrder`.
- `cat /etc/machine-id` equals the staged id; `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` equals the staged fingerprint.
- `systemctl --failed` prints `0 loaded units listed`.
- `fprintd-enroll` succeeds; afterwards `sudo -k; sudo true` accepts a finger.
- `fwupdmgr get-devices` lists the system firmware and the fingerprint reader.
- Speakers, headset jack, Wi-Fi, and Bluetooth each work once.

Optional: delete stale firmware boot entries with
`nix shell .#efibootmgr -c sudo efibootmgr -b <id> -B`
after confirming each points at a partition that no longer exists.

## Cleanup (fish, on argentite)

Only after the post-install checks pass, since Rollback re-runs step 3 and
needs the staged files:

```fish
rm -rf $work
```

## Rollback

The disk was blank, so a failed install loses nothing. Fix the configuration
and re-run step 3. If the first boot cannot import the pool, boot the stick,
run `zpool import -f <pool>` then `zpool export <pool>`, and reboot.
