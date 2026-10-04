# ilmenite Laptop Bringup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `ilmenite` NixOS host (Framework Laptop 13 Pro, Intel Core
Ultra Series 3) to the fleet, install it with nixos-anywhere, and measure its
standby power behaviour.

**Architecture:** ilmenite is a clone of malachite's host pattern (ZFS native
encryption, root rollback to an empty snapshot, impermanence bind mounts,
systemd-boot, Plasma) with three differences: the Series 3 nixos-hardware
module, a random-encrypted swap partition with no resume device, and
`stateVersion = "26.05"`. The install runs from argentite over SSH against the
live ISO already booted on the laptop. The standby spike is measurement only
and produces an investigation document.

**Tech Stack:** NixOS unstable (flake pin `nixos-26.11.20260905.c043004`),
kernel `linuxPackages_6_18`, disko, impermanence, nixos-hardware,
nixos-anywhere 1.13.0, OpenZFS 2.4.4, Plasma 6.

**Spec:** `docs/plans/active/ilmenite-laptop-bringup.md`

## Global Constraints

- Hostname and directory name are both `ilmenite`; the host assertion in
  `nixos-configurations/default.nix` requires a `knownHosts` entry.
- `system.stateVersion = "26.05"` and `home.stateVersion = "26.05"`.
- `boot.kernelPackages = pkgs.linuxPackages_6_18`; the Series 3 module asserts
  kernel >= 6.17.
- `users.mutableUsers = false`; passwords via `hashedPassword` with fresh
  SHA-512 hashes, never malachite's.
- No hibernation: no `resumeDevice`, no `boot.zfs.unsafeAllowHibernation`;
  the kernel command line must contain `nohibernate` and no `resume=`.
- Swap: 32G, `randomEncryption = true`.
- ZFS: `encryption = "aes-256-gcm"`, `keyformat = "passphrase"`,
  `keylocation = "file:///tmp/secret.key"` at create time, switched to
  `prompt` by a zpool `postCreateHook`.
- `boot.zfs.forceImportRoot = true` (fleet parity).
- `hardware.intelgpu.driver = "xe"` and
  `hardware.intelgpu.vaapiDriver = "intel-media-driver"`.
- `hardware.framework.enableKmod` stays at its default (`true`).
- No sops secrets file, no Secure Boot, no speaker EQ, no NVMe LBA reformat,
  no ZFS ARC cap.
- The other four hosts' `system.build.toplevel.drvPath` values must not
  change (baseline recorded in Task 6).
- Every commit subject uses the repo's attr-path style and ends with the
  trailer `Assisted-by: Claude Code (claude-fable-5-1)`. No co-author
  trailers.
- Run `nix fmt <file>` on every new or edited file; `git diff --exit-code`
  after formatting must be clean.
- New files must be `git add -N`'d before any `nix eval`/`nix build`, or the
  flake cannot see them.
- Commands the user runs on argentite are fish; commands the executor runs
  through the Bash tool are bash. Each block says which.
- Work happens on branch `djacu/ilmenite-bringup`. Leave the pre-existing
  uncommitted changes in the working tree alone (`.claude/settings.local.json`,
  the staged `docs/plans/active/scheelite-remote-access.md`, `songs/`).

## Review Focus

1. A passphrase file with anything other than exactly one trailing newline
   (CRLF, trailing space) creates a pool the typed prompt cannot open.
   Expected: the file holds the passphrase plus a single `\n`. Pinned to
   Task 5 step 4 (runbook) and Task 7 step 2.
1. The disko device path not existing on the target makes disko fail before
   formatting; a path that resolves to the wrong disk would format it.
   Expected: the by-id path exists and resolves to the only NVMe. Pinned to
   Task 7 step 1.
1. Firmware boot order after install still preferring the USB stick or PXE
   over the new NixOS entry. Expected: `Linux Boot Manager` is first in
   `BootOrder`. Pinned to Task 7 step 6.
1. SDDM with fprintd enabled but no enrolled fingers must still accept the
   password. Expected: password login works before `fprintd-enroll` runs.
   Pinned to Task 7 step 5.
1. `/persist/etc/machine-id` or the SSH host keys missing after
   `--extra-files` makes the system mint a new identity on first boot.
   Expected: the booted machine-id and host key fingerprint equal the staged
   ones. Pinned to Task 7 step 6.

______________________________________________________________________

### Task 0: Password hashes (user input)

**Files:**

- Create (scratchpad, never committed):
  `$SCRATCH/ilmenite/root.hash`, `$SCRATCH/ilmenite/djacu.hash`

**Interfaces:**

- Produces: two files, each one line, a SHA-512 crypt hash starting with
  `$6$`. Task 2 substitutes them into `default.nix`.

- [ ] **Step 1: User generates the hashes (fish, on argentite)**

```fish
nix shell .#mkpasswd -c mkpasswd -m sha-512
```

Run once for root and once for `djacu`, typing each new password at the
prompt. Paste the two output lines to the executor.

- [ ] **Step 2: Executor stores them (bash)**

```bash
S=/tmp/claude-1000/-home-djacu-dev-djacu-theonecfg/42a34f7a-8b1a-4ee7-b28b-f8835bb52e56/scratchpad
mkdir -p "$S/ilmenite"
printf '%s\n' '<root hash>' > "$S/ilmenite/root.hash"
printf '%s\n' '<djacu hash>' > "$S/ilmenite/djacu.hash"
```

- [ ] **Step 3: Verify the shape**

Run: `grep -c '^\$6\$' "$S/ilmenite/root.hash" "$S/ilmenite/djacu.hash"`
Expected: both files report `1`.

______________________________________________________________________

### Task 1: Register the host and the hardware module

**Files:**

- Modify: `theonecfg/default.nix` (knownHosts block and nixosHardware inherit
  list)

**Interfaces:**

- Produces: `theonecfg.knownHosts.ilmenite = { type = "laptop"; forwardAgent = true; }`
  and `theonecfg.nixosHardware.framework-intel-core-ultra-series3`. Task 2's
  host assertion and import depend on both.

- [ ] **Step 1: Run the checks to see them fail (bash)**

```bash
nix eval --json .#theonecfg.knownHosts.ilmenite
nix eval --json .#theonecfg.nixosHardware --apply builtins.attrNames
```

Expected: the first errors with `does not provide attribute ... theonecfg.knownHosts.ilmenite`;
the second prints `["framework-11th-gen-intel","lenovo-thinkpad-t480"]`.

- [ ] **Step 2: Add the knownHosts entry**

In `theonecfg/default.nix`, insert between the `cassiterite` and `malachite`
entries so the set stays alphabetical:

```nix
    ilmenite = {
      type = "laptop";
      forwardAgent = true;
    };
```

- [ ] **Step 3: Add the hardware module**

Change the `nixosHardware` block to:

```nix
  nixosHardware = {
    inherit (inputs.nixos-hardware.nixosModules)
      framework-11th-gen-intel
      framework-intel-core-ultra-series3
      lenovo-thinkpad-t480
      ;
  };
```

- [ ] **Step 4: Format and re-run the checks**

```bash
nix fmt theonecfg/default.nix
nix eval --json .#theonecfg.knownHosts.ilmenite
nix eval --json .#theonecfg.nixosHardware --apply builtins.attrNames
```

Expected: `{"forwardAgent":true,"type":"laptop"}` and
`["framework-11th-gen-intel","framework-intel-core-ultra-series3","lenovo-thinkpad-t480"]`.

- [ ] **Step 5: Commit**

```bash
git add theonecfg/default.nix
git commit -m "theonecfg: add ilmenite to knownHosts and nixosHardware

ilmenite is a Framework Laptop 13 Pro (Intel Core Ultra Series 3).
Expose nixos-hardware's framework-intel-core-ultra-series3 module next
to the existing Framework and ThinkPad ones.

Assisted-by: Claude Code (claude-fable-5-1)" -- theonecfg/default.nix
```

______________________________________________________________________

### Task 2: NixOS configuration for ilmenite

**Files:**

- Create: `nixos-configurations/ilmenite/default.nix`
- Create: `nixos-configurations/ilmenite/disko.nix`
- Create: `nixos-configurations/ilmenite/hardware.nix`
- Create: `nixos-configurations/ilmenite/impermanence.nix`

**Interfaces:**

- Consumes: `theonecfg.knownHosts.ilmenite`,
  `theonecfg.nixosHardware.framework-intel-core-ultra-series3` (Task 1);
  the two hash files (Task 0).

- Produces: `nixosConfigurations.ilmenite` with
  `config.system.build.toplevel`, `networking.hostId = "1166a74d"`, and a
  disko layout nixos-anywhere consumes in Task 7.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
nix eval --raw .#nixosConfigurations.ilmenite.config.networking.hostId
```

Expected: `does not provide attribute ... nixosConfigurations.ilmenite...`.

- [ ] **Step 2: Create `default.nix`**

```nix
inputs: {
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
  };
  modules =
    {
      config,
      lib,
      pkgs,
      theonecfg,
      ...
    }:
    {
      imports = [
        ./disko.nix
        ./hardware.nix
        ./impermanence.nix

        theonecfg.nixosHardware.framework-intel-core-ultra-series3
      ];
      config = {
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "26.05";

        boot.kernelPackages = pkgs.linuxPackages_6_18;
        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.efi.efiSysMountPoint = "/boot";
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.devNodes = "/dev/disk/by-id";
        # Kept true for parity with the other hosts. Recovery from an unclean
        # pool is zfs_force=1 from the systemd-boot editor, which is enabled.
        boot.zfs.forceImportRoot = true;

        boot.initrd.systemd.services.rollback-root = {
          description = "Rollback ZFS root to empty snapshot";
          wantedBy = [ "initrd.target" ];
          after = [ "zfs-import-zroot.service" ];
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig.Type = "oneshot";
          path = [ config.boot.zfs.package ];
          script = ''
            zfs rollback -r zroot/local/root@empty && echo "rollback of zroot complete"
          '';
        };

        hardware.bluetooth.enable = true;

        # Panther Lake is xe-only. nixos-hardware's shared Intel GPU module
        # still defaults to i915 in the initrd and installs both VAAPI
        # drivers; the Lunar Lake module makes the same two overrides.
        hardware.intelgpu.driver = "xe";
        hardware.intelgpu.vaapiDriver = "intel-media-driver";

        networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

        security.sudo.extraConfig = ''
          # rollback results in sudo lectures after each reboot
          Defaults lecture = never
        '';

        services.zfs.autoScrub.enable = true;

        time.timeZone = "America/Los_Angeles";

        users.mutableUsers = false;
        users.users.root.hashedPassword = "@ROOT_HASH@";

        theonecfg.profiles.common.enable = true;
        theonecfg.profiles.desktop.enable = true;

        theonecfg.users.djacu.enable = true;
        users.users.djacu.hashedPassword = "@DJACU_HASH@";
      };
    };
}
```

- [ ] **Step 3: Substitute the hashes from Task 0 (bash)**

```bash
S=/tmp/claude-1000/-home-djacu-dev-djacu-theonecfg/42a34f7a-8b1a-4ee7-b28b-f8835bb52e56/scratchpad
F=nixos-configurations/ilmenite/default.nix
sed -i -e "s|@ROOT_HASH@|$(cat "$S/ilmenite/root.hash")|" -e "s|@DJACU_HASH@|$(cat "$S/ilmenite/djacu.hash")|" "$F"
grep -c '@[A-Z_]*HASH@' "$F"; grep -c 'hashedPassword = "\$6\$' "$F"
```

Expected: `0` then `2`. (Hashes contain `$` and `/` but no `|`, so the sed
delimiter is safe.)

- [ ] **Step 4: Create `disko.nix`**

```nix
{
  disko.devices = {
    disk = {
      disk1 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_25356W800320";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = "32G";
              type = "8200";
              content = {
                type = "swap";
                # Fresh key on every boot. No hibernation, so no resumeDevice.
                randomEncryption = true;
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          acltype = "posixacl";
          canmount = "off";
          checksum = "edonr";
          compression = "lz4";
          dnodesize = "auto";
          # encryption does not appear to work in vm test; only use on real system
          encryption = "aes-256-gcm";
          keyformat = "passphrase";
          # Install-time only. nixos-anywhere uploads the passphrase to this
          # path on the installer (--disk-encryption-keys) because disko runs
          # without a terminal. postCreateHook switches the pool to prompt
          # before the first boot.
          keylocation = "file:///tmp/secret.key";
          normalization = "formD";
          relatime = "on";
          xattr = "sa";
        };
        mountpoint = null;
        options = {
          ashift = "12";
          autotrim = "on";
        };
        postCreateHook = ''
          zfs set keylocation=prompt zroot
        '';

        datasets = {
          local = {
            type = "zfs_fs";
            options.canmount = "off";
          };

          safe = {
            type = "zfs_fs";
            options.canmount = "off";
          };

          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options.mountpoint = "/";
            postCreateHook = ''
              zfs snapshot zroot/local/root@empty
            '';
          };

          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.mountpoint = "/nix";
          };

          "safe/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options.mountpoint = "/home";
          };

          "safe/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options.mountpoint = "/persist";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 5: Create `hardware.nix`**

This is the live ISO's `nixos-generate-config --no-filesystems` output from
2026-10-03, formatted like the other hosts' files.

```nix
# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "uas"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.npu.enable = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
```

- [ ] **Step 6: Create `impermanence.nix` as a copy of malachite's (bash)**

```bash
cp nixos-configurations/malachite/impermanence.nix nixos-configurations/ilmenite/impermanence.nix
diff nixos-configurations/malachite/impermanence.nix nixos-configurations/ilmenite/impermanence.nix && echo IDENTICAL
```

Expected: `IDENTICAL`.

- [ ] **Step 7: Track the files and format (bash)**

```bash
git add -N nixos-configurations/ilmenite
nix fmt nixos-configurations/ilmenite
git diff --stat -- nixos-configurations/ilmenite
```

Expected: four files listed as added.

- [ ] **Step 8: Run the eval gates (bash)**

```bash
H=.#nixosConfigurations.ilmenite.config
nix eval --raw "$H.networking.hostId"; echo
nix eval --raw "$H.boot.resumeDevice"; echo "<end>"
nix eval --json "$H.boot.kernelParams"
nix eval --json "$H.swapDevices"
nix eval --json "$H.boot.initrd.kernelModules"
nix eval --json "$H.hardware.intelgpu" --apply 'g: { inherit (g) driver vaapiDriver loadInInitrd; }'
nix eval "$H.hardware.framework.enableKmod"
nix eval "$H.services.fprintd.enable"
nix eval "$H.services.fwupd.enable"
nix eval "$H.hardware.cpu.intel.npu.enable"
nix eval "$H.boot.loader.systemd-boot.editor"
nix eval --json "$H.disko.devices.zpool.zroot.rootFsOptions"
nix eval --raw "$H.disko.devices.zpool.zroot.postCreateHook"
nix eval --json "$H.fileSystems" --apply 'fs: builtins.mapAttrs (n: v: { inherit (v) device fsType options; }) fs'
nix eval "$H.system.stateVersion"
```

Expected, line by line:

| Check                             | Expected                                                                                                                                                                                            |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `networking.hostId`               | `1166a74d`                                                                                                                                                                                          |
| `boot.resumeDevice`               | nothing before `<end>`                                                                                                                                                                              |
| `boot.kernelParams`               | contains `"nvme.noacpi=1"` and `"nohibernate"`; contains no element starting with `resume=`                                                                                                         |
| `swapDevices`                     | one entry: `device = "/dev/disk/by-partlabel/disk-disk1-swap"`, `randomEncryption.enable = true`, `realDevice = "/dev/mapper/dev-disk-byx2dpartlabel-diskx2ddisk1x2dswap"`                          |
| `boot.initrd.kernelModules`       | contains `"xe"` and `"zfs"`, not `"i915"`                                                                                                                                                           |
| `hardware.intelgpu`               | `{"driver":"xe","loadInInitrd":true,"vaapiDriver":"intel-media-driver"}`                                                                                                                            |
| `hardware.framework.enableKmod`   | `true`                                                                                                                                                                                              |
| `services.fprintd.enable`         | `true`                                                                                                                                                                                              |
| `services.fwupd.enable`           | `true`                                                                                                                                                                                              |
| `hardware.cpu.intel.npu.enable`   | `true`                                                                                                                                                                                              |
| `boot.loader.systemd-boot.editor` | `true`                                                                                                                                                                                              |
| `rootFsOptions`                   | `encryption = "aes-256-gcm"`, `keyformat = "passphrase"`, `keylocation = "file:///tmp/secret.key"`, `canmount = "off"`                                                                              |
| zpool `postCreateHook`            | `zfs set keylocation=prompt zroot`                                                                                                                                                                  |
| `fileSystems`                     | `/` = `zroot/local/root`, `/nix` = `zroot/local/nix`, `/home` = `zroot/safe/home`, `/persist` = `zroot/safe/persist`, all `fsType = "zfs"` with `"zfsutil"` in options; `/boot` = `fsType = "vfat"` |
| `system.stateVersion`             | `"26.05"`                                                                                                                                                                                           |

Any mismatch: fix the file, re-run the whole block.

- [ ] **Step 9: Build the system (bash)**

```bash
nix build --no-link --print-out-paths .#nixosConfigurations.ilmenite.config.system.build.toplevel
```

Expected: a `/nix/store/...-nixos-system-ilmenite-...` path. This is also the
proof that `framework-laptop-kmod` compiles against the pinned 6.18 kernel.
A failure in that module means: stop, report, and decide with the user
between `hardware.framework.enableKmod = false` and waiting on upstream.

- [ ] **Step 10: Commit**

```bash
git add nixos-configurations/ilmenite
git commit -m "nixosConfigurations.ilmenite: init

Framework Laptop 13 Pro (Intel Core Ultra Series 3), board FRANMJCP07,
BIOS 03.02, 64 GB, WD_BLACK SN850X 2 TB. Cloned from malachite with
three differences:

- nixos-hardware framework-intel-core-ultra-series3 instead of the
  11th-gen module, plus hardware.intelgpu.driver = xe and the media
  VAAPI driver because Panther Lake is xe-only and the shared Intel
  GPU module still defaults to i915.
- swap uses randomEncryption and has no resumeDevice; hibernation is
  out of scope.
- ZFS keylocation is a file during the nixos-anywhere install and a
  zpool postCreateHook switches it to prompt before first boot.

hardware.nix is nixos-generate-config output from the 26.05 live ISO.
Passwords use hashedPassword with fresh hashes.

Assisted-by: Claude Code (claude-fable-5-1)" -- nixos-configurations/ilmenite
```

______________________________________________________________________

### Task 3: home-manager configuration

**Files:**

- Create: `home-configurations/ilmenite/djacu/default.nix`

**Interfaces:**

- Produces: `homeConfigurations.ilmenite-djacu` with `activationPackage`,
  applied in Task 7 step 5.

- [ ] **Step 1: Run the gate to see it fail (bash)**

```bash
nix eval --raw .#homeConfigurations.ilmenite-djacu.activationPackage.name
```

Expected: `does not provide attribute ... homeConfigurations.ilmenite-djacu...`.

- [ ] **Step 2: Create the file**

```nix
inputs: {
  system = "x86_64-linux";
  release = rec {
    number = "unstable";
    nixpkgs = inputs."nixpkgs-${number}";
    home-manager = inputs."home-manager-${number}";
  };
  modules = [
    {

      home.stateVersion = "26.05";

      theonecfg.users.djacu.enable = true;

      theonecfg.users.djacu.profiles.common.enable = true;
      theonecfg.users.djacu.profiles.desktop.enable = true;
      theonecfg.users.djacu.profiles.developer.enable = true;

    }
  ];
}
```

- [ ] **Step 3: Track, format, verify identical to malachite's (bash)**

```bash
git add -N home-configurations/ilmenite
nix fmt home-configurations/ilmenite
diff home-configurations/malachite/djacu/default.nix home-configurations/ilmenite/djacu/default.nix && echo IDENTICAL
```

Expected: `IDENTICAL`.

- [ ] **Step 4: Build (bash)**

```bash
nix build --no-link --print-out-paths .#homeConfigurations.ilmenite-djacu.activationPackage
```

Expected: a `/nix/store/...-home-manager-generation` path.

- [ ] **Step 5: Commit**

```bash
git add home-configurations/ilmenite
git commit -m "homeConfigurations.ilmenite.djacu: init

Same common, desktop, and developer profiles as malachite.

Assisted-by: Claude Code (claude-fable-5-1)" -- home-configurations/ilmenite
```

______________________________________________________________________

### Task 4: Ore naming reference

**Files:**

- Modify: `docs/reference/ores.md` (the `titanium | ilmenite` row)

- [ ] **Step 1: Check the current row (bash)**

```bash
grep -n '| ilmenite' docs/reference/ores.md
```

Expected: a row with `—` in the role and hardware columns.

- [ ] **Step 2: Fill the row (bash)**

```bash
sed -i 's/^| titanium *| ilmenite *| — *| — *| — *|$/| titanium | ilmenite | laptop | Framework 13 Pro (Core Ultra Series 3) | — |/' docs/reference/ores.md
nix fmt docs/reference/ores.md
grep -n '| ilmenite' docs/reference/ores.md
```

Expected: the row shows `laptop` and `Framework 13 Pro (Core Ultra Series 3)`.
If the sed matched nothing (row text differs), edit the row by hand to the
same values and re-run `nix fmt`.

- [ ] **Step 3: Commit**

```bash
git add docs/reference/ores.md
git commit -m "docs/reference/ores.md: assign ilmenite to the Framework Laptop 13 Pro

Assisted-by: Claude Code (claude-fable-5-1)" -- docs/reference/ores.md
```

______________________________________________________________________

### Task 5: Install runbook

**Files:**

- Create: `docs/runbooks/install-laptop-with-nixos-anywhere.md`

**Interfaces:**

- Produces: the procedure Task 7 follows verbatim.

- [ ] **Step 1: Create the runbook**

````markdown
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
   rm -rf $work
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
- `sudo efibootmgr` shows `Linux Boot Manager` first in `BootOrder`.
- `cat /etc/machine-id` equals the staged id; `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` equals the staged fingerprint.
- `systemctl --failed` prints `0 loaded units listed`.
- `fprintd-enroll` succeeds; afterwards `sudo -k; sudo true` accepts a finger.
- `fwupdmgr get-devices` lists the system firmware and the fingerprint reader.
- Speakers, headset jack, Wi-Fi, and Bluetooth each work once.

Optional: delete stale firmware boot entries with `sudo efibootmgr -b <id> -B`
after confirming each points at a partition that no longer exists.

## Rollback

The disk was blank, so a failed install loses nothing. Fix the configuration
and re-run step 3. If the first boot cannot import the pool, boot the stick,
run `zpool import -f <pool>` then `zpool export <pool>`, and reboot.
````

- [ ] **Step 2: Track and format (bash)**

```bash
git add -N docs/runbooks/install-laptop-with-nixos-anywhere.md
nix fmt docs/runbooks/install-laptop-with-nixos-anywhere.md
```

- [ ] **Step 3: Syntax-check every fish block (bash)**

````bash
awk '/^ *```fish$/{f=1;next} /^ *```$/{f=0} f' docs/runbooks/install-laptop-with-nixos-anywhere.md \
  | sed -e 's/<host>/ilmenite/g' -e 's/<ip>/10.0.10.80/g' -e 's/<user>/djacu/g' -e 's/<root password set on the live ISO>/password/' -e 's/<pool>/zroot/g' \
  | fish --no-execute && echo FISH-SYNTAX-OK
````

Expected: `FISH-SYNTAX-OK`.

- [ ] **Step 4: Verify the passphrase-file check is present (bash)**

```bash
grep -c "od -c \$work/zfs.key" docs/runbooks/install-laptop-with-nixos-anywhere.md
```

Expected: `1`. (Review Focus item 1.)

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/install-laptop-with-nixos-anywhere.md
git commit -m "docs/runbooks: add install-laptop-with-nixos-anywhere

Remote install of a ZFS-encrypted impermanence laptop from argentite:
passphrase via --disk-encryption-keys, host identity seeded into the
persist dataset via --extra-files, post-install checks, rollback.

Assisted-by: Claude Code (claude-fable-5-1)" -- docs/runbooks/install-laptop-with-nixos-anywhere.md
```

______________________________________________________________________

### Task 6: Fleet-safety gate, formatting gate, and pull request

**Files:**

- None modified. Reads the scratchpad baseline from
  `$SCRATCH/ilmenite/fleet-drv-before.txt`.

**Interfaces:**

- Consumes: all commits from Tasks 1 through 5.

- [ ] **Step 1: Compare the four existing hosts' derivations (bash)**

Baseline recorded on 2026-10-03 at commit `fb9a58b` (before any Nix change):

```
malachite   /nix/store/fd6af4cbg0vgfl7xkvf885p0zd8zxy76-nixos-system-malachite-26.11.20260905.c043004.drv
cassiterite /nix/store/acmh411ymlvcf83h32mbgqkjlhxw1c9p-nixos-system-cassiterite-26.11.20260905.c043004.drv
argentite   /nix/store/rzw6dfkl5yfgi8h4jd5vza029svpdd6i-nixos-system-argentite-26.11.20260905.c043004.drv
scheelite   /nix/store/rlh4m5fjz9nm70rcz40zc58yv9r3qm9z-nixos-system-scheelite-26.11.20260905.c043004.drv
```

```bash
for h in malachite cassiterite argentite scheelite; do
  printf '%s %s\n' "$h" "$(nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath)"
done
```

Expected: the four paths above, unchanged. Any difference means
`theonecfg/default.nix` changed more than it should; diff that file against
`main` and fix before continuing.

- [ ] **Step 2: Formatting gate (bash)**

```bash
nix fmt theonecfg nixos-configurations/ilmenite home-configurations/ilmenite docs/reference/ores.md docs/runbooks/install-laptop-with-nixos-anywhere.md docs/plans/active/ilmenite-laptop-bringup.md docs/plans/active/ilmenite-laptop-bringup-implementation.md
git diff --exit-code && echo FORMAT-CLEAN
```

Expected: `FORMAT-CLEAN`.

- [ ] **Step 3: Review the branch (bash)**

```bash
git log --oneline main..HEAD
git diff --stat main..HEAD
```

Expected: eight commits (two plan docs, theonecfg, nixosConfigurations,
homeConfigurations, ores, runbook, plus this implementation plan's own
commit) and only the files named in this plan.

- [ ] **Step 4: Push and open the PR (bash, only when the user says to)**

```bash
git push -u origin djacu/ilmenite-bringup
gh pr create --title "nixosConfigurations.ilmenite: Framework Laptop 13 Pro bringup" --body "Adds ilmenite, a Framework Laptop 13 Pro (Intel Core Ultra Series 3), modelled on malachite. Differences: the Series 3 nixos-hardware module with an xe GPU override, random-encrypted swap with no hibernation, and a ZFS keylocation handoff that lets nixos-anywhere format the encrypted pool non-interactively. Includes the install runbook and the design and implementation plans.

Install and the standby power investigation happen after merge and are tracked in docs/plans/active/ilmenite-laptop-bringup.md.

Assisted-by: Claude Code (claude-fable-5-1)"
```

______________________________________________________________________

### Task 7: Install ilmenite

**Files:**

- None in the repo. Follows `docs/runbooks/install-laptop-with-nixos-anywhere.md`
  with `<host>` = `ilmenite`, `<ip>` = `10.0.10.80`, `<pool>` = `zroot`,
  `<user>` = `djacu`.

**Interfaces:**

- Consumes: the built toplevel (Task 2), the runbook (Task 5).
- Produces: a booted ilmenite that Task 8 measures.

The user runs the fish steps on argentite because they involve the ZFS
passphrase and the live ISO's root password. The executor verifies.

- [ ] **Step 1: Disk id check (user, fish)**

Runbook step 1. Expected: `nvme-WD_BLACK_SN850X_2000GB_25356W800320 -> ../../nvme0n1`
and `lsblk` showing `WD_BLACK SN850X 2000GB` serial `25356W800320`.
(Review Focus item 2.)

- [ ] **Step 2: Stage passphrase and identity (user, fish)**

Runbook step 2. Expected: `od -c` ends in the last passphrase character then
`\n`; a fingerprint line and a 32-hex machine-id are printed. The user
pastes the fingerprint and machine-id to the executor, who stores them:

```bash
S=/tmp/claude-1000/-home-djacu-dev-djacu-theonecfg/42a34f7a-8b1a-4ee7-b28b-f8835bb52e56/scratchpad
printf '%s\n' '<fingerprint line>' > "$S/ilmenite/staged-hostkey.txt"
printf '%s\n' '<machine-id>' > "$S/ilmenite/staged-machine-id.txt"
```

(Review Focus item 1.)

- [ ] **Step 3: Run nixos-anywhere (user, fish)**

Runbook step 3. Expected: output passes through phases `disko`, `install`,
`reboot`; the disko phase prints `zpool create` and
`zfs set keylocation=prompt zroot`; the final line reports the reboot. If
the disko phase fails on the device path, return to step 1.

- [ ] **Step 4: First boot (user, on the laptop)**

Expected: `Enter key for zroot` prompt; typing the passphrase continues to
SDDM.

- [ ] **Step 5: Password login before any enrollment (user, on the laptop)**

Log in to Plasma as `djacu` with the password. Expected: login succeeds
with no fingerprint enrolled. (Review Focus item 4.) Then apply home-manager
per runbook step 5.

- [ ] **Step 6: Post-install checks (user on the laptop, or executor over SSH as djacu if the agent can sign)**

Run every line of the runbook's post-install list. Record each result. The
identity and boot-order lines are Review Focus items 3 and 5:

```bash
sudo efibootmgr | grep -E 'BootOrder|Linux Boot Manager'
cat /etc/machine-id
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Expected: `BootOrder` starts with the id of `Linux Boot Manager`; the
machine-id and fingerprint equal the staged values from step 2.

- [ ] **Step 7: Record the outcome**

Append a dated "Install log" section to
`docs/plans/active/ilmenite-laptop-bringup.md` listing each check and its
result, then:

```bash
git add docs/plans/active/ilmenite-laptop-bringup.md
git commit -m "docs/plans/active: ilmenite install log

Assisted-by: Claude Code (claude-fable-5-1)" -- docs/plans/active/ilmenite-laptop-bringup.md
```

______________________________________________________________________

### Task 8: Standby power spike

**Files:**

- Create: `docs/investigations/ilmenite-standby-power.md`

**Interfaces:**

- Consumes: the booted ilmenite (Task 7).

- Produces: measurements and a recommendation; any configuration change is a
  new bounded task, not part of this plan.

- [ ] **Step 1: Baseline (on the laptop, bash)**

```bash
cat /sys/class/dmi/id/bios_version
cat /sys/power/mem_sleep
journalctl --list-boots | tail -n 3
sudo cat /sys/kernel/debug/pmc_core/substate_residencies
```

Record all four outputs. Expected `mem_sleep`: `[s2idle]`.

- [ ] **Step 2: Measurement script (on the laptop, bash)**

Save as `~/standby-measure.sh`:

```bash
#!/usr/bin/env bash
# Usage: sudo ./standby-measure.sh before|after <label>
set -eu
phase=$1; label=$2
out=~/standby-$label-$phase.txt
{
  date +%s
  cat /sys/class/power_supply/BAT1/charge_now
  cat /sys/class/power_supply/BAT1/voltage_now
  cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec
  cat /sys/kernel/debug/pmc_core/substate_residencies
  if [ "$phase" = after ]; then
    journalctl -b -k | grep -E 'PM: suspend (entry|exit)' | tail -n 2
    cat /sys/kernel/debug/pmc_core/s0ix_blocker || true
    journalctl -b -k | grep -ic BERT || true
  fi
} > "$out"
echo "wrote $out"
```

`chmod +x ~/standby-measure.sh`.

- [ ] **Step 3: Scenario A, nothing plugged in**

On battery, no expansion cards, no hub: `sudo ./standby-measure.sh before a`,
close the lid for 30 minutes by the clock, open it, log in,
`sudo ./standby-measure.sh after a`. Expected: both files written; the
`after` file shows a `suspend exit` line and a BERT count of `0`.

- [ ] **Step 4: Scenario B, expansion cards installed**

Same procedure with label `b`.

- [ ] **Step 5: Scenario C, USB-C hub and Ethernet attached**

Same procedure with label `c`.

- [ ] **Step 6: powertop baseline**

On battery, idle, lid open: `sudo powertop --html=$HOME/powertop.html`. Keep
the file for the write-up. Do not run `--auto-tune`.

- [ ] **Step 7: Compute and decide**

For each scenario: drain in %/h = (charge_before − charge_after) / 4737000 ×
100 / 0.5; Wh/h = (charge_before − charge_after) × average voltage / 1e12 / 0.5;
S0ix residency = (slp_s0_after − slp_s0_before) / (time_after − time_before)
/ 1e6. Apply the spec's decision rules: residency above 90% and drain under
about 1%/h means s2idle is healthy; otherwise identify blockers from
`s0ix_blocker` and powertop; any BERT record means lid-close sleep is unsafe
on this BIOS.

- [ ] **Step 8: Write the investigation and commit**

`docs/investigations/ilmenite-standby-power.md` with: date, BIOS and kernel
versions, the three scenario tables (drain %/h, Wh/h, residency, BERT count),
the powertop top consumers, and the recommendation. Then:

```bash
git add -N docs/investigations/ilmenite-standby-power.md
nix fmt docs/investigations/ilmenite-standby-power.md
git add docs/investigations/ilmenite-standby-power.md
git commit -m "docs/investigations: ilmenite standby power measurements

Assisted-by: Claude Code (claude-fable-5-1)" -- docs/investigations/ilmenite-standby-power.md
```

______________________________________________________________________

### Task 9: Close out

**Files:**

- Move: `docs/plans/active/ilmenite-laptop-bringup.md` to
  `docs/plans/completed/`

- Move: `docs/plans/active/ilmenite-laptop-bringup-implementation.md` to
  `docs/plans/completed/`

- [ ] **Step 1: Update the status lines and move (bash)**

```bash
sed -i 's/^\*\*Status:\*\* .*$/**Status:** Completed <date>; standby findings in docs\/investigations\/ilmenite-standby-power.md/' docs/plans/active/ilmenite-laptop-bringup.md
git mv docs/plans/active/ilmenite-laptop-bringup.md docs/plans/completed/
git mv docs/plans/active/ilmenite-laptop-bringup-implementation.md docs/plans/completed/
nix fmt docs/plans/completed/ilmenite-laptop-bringup.md docs/plans/completed/ilmenite-laptop-bringup-implementation.md
git diff --cached --stat
```

Replace `<date>` with the day the install log was written. Expected: two
renames.

- [ ] **Step 2: Commit**

```bash
git commit -m "docs/plans: complete ilmenite laptop bringup

Assisted-by: Claude Code (claude-fable-5-1)"
```
