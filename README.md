# theonecfg

## architecture

### formatter

Formatter setup to use for the repository.

### homeConfigurations

Home-manager configurations for a combination of host and user.
They are accessed via `homeConfigurations.<host>-<user>` attributes.

### homeModules

Home-manager modules under `theonecfg` namespace gated behind `enable` options.
Modules are grouped in directories by `programs`, `services`, or a `<user>`.
Modules created for one user are not available to another user to enable.
Modules not under a `<user>` directory are available for all users to define.
See `mkUserModules` for details about how modules are filtered.
They are accessed via `homeModules.<user>` attributes.

### hydra-jobs

Jobset files for Hydra, in nixpkgs' release-lib style.
Each file is a function producing `<job>.<system>` attributes and is evaluated by path, not through a flake output.

| file                       | jobs                                                                                          |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `packages.nix`             | every package under `overlays/topLevel/`                                                      |
| `vm-tests.nix`             | every VM test under `overlays/nixosTests/`, as `theonecfgNixosTests.<test>`                   |
| `nixos-configurations.nix` | every host in `nixosConfigurations`: the toplevel, VM, or ISO its `knownHosts` type calls for |
| `home-configurations.nix`  | every `homeConfigurations.<host>-<user>` activation package                                   |

`theonecfg-verify-hydra-jobset` evaluates a jobset file and builds every job:

```sh
nix run .#theonecfg-verify-hydra-jobset -- ./hydra-jobs/packages.nix
```

CI runs `packages.nix` and `vm-tests.nix`.
The configuration jobsets do not fit a free runner; run them locally before merging a change to a host or a user.

The jobset files see the flake through `builtins.getFlake "git+file://..."`, which only sees git-tracked files.
A new directory must be `git add`ed before any jobset sees it.

### legacyPackages

A nixpkgs package set with `theonecfg` overlays applied.

### nixosConfigurations

NixOS configurations for a host.
They are accessed via `nixosConfigurations.<host>`.

### nixosModules

NixOS modules under `theonecfg` namespace gated behind `enable` options.
There is currently little structure here except for user specific modules which are in directories.

### overlays

Centralized overlays to be used elsewhere in `theonecfg`.
Package sources live here, one subdirectory per overlay, each spelled like the overlay attribute it produces:
`topLevel/` holds one `package.nix` per package, exposed as `pkgs.<name>`;
`nixosTests/` holds the VM tests, exposed as `pkgs.theonecfgNixosTests.<name>`;
`fixes/` holds `overlay.nix` files amending upstream packages;
`inputOverlays/` holds one `overlay.nix` per flake input that ships packages.
Currently used in `legacyPackages`, `nixosModules`, `homeConfigurations`, and `hydra-jobs/common.nix`.

## hosts

### scheelite

#### bootstrap

1. Get into the root user.
   1. `sudo -i`
1. Wipe all old disk information and check that it looks correct.
   1. `wipefs --all /dev/disk/by-id/wwn-0x5000*`
   1. `wipefs --all /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB*`
   1. `lsblk -f`
1. Clone the repository.
   1. `nix-shell -p git neovim`
   1. `git clone https://github.com/djacu/theonecfg.git`
   1. `cd theonecfg`
1. Partition the drives.
   This creates a new temporary directory where the drives are mounted.
   For example, `/tmp/tmp.kWXrNPDsDG/`, which is set to `MNT` in the setup script.
   1. `cd nixosConfigurations/scheelite`
   1. `./setup.sh`
   1. `cd -`
1. If there have been hardware changes, regenerate the hardware configuration.
   Copy it over from `/etc` into the repository and compare the two files.
   1. `nixos-generate-config --root <MNT>`
   1. The generated file will be not be formatted unlike the file in the repository.
      In the generated file, swap devices will sometimes get mapped to `/dev/disk/by-uuid`.
      Partition order is fixed, so it is okay to leave them mapped how they are, `/dev/xyz`.
   1. In the generated file, all file systems, including ZFS pools, will be populated.
      If non-legacy mountpoints are used, they should not be included in the `fileSystems` entries.
      Except for the ones that are required for initrd and those should have `options = ["zfsutil"];`.[^1]
1. Install
   1. `sudo nixos-install --no-root-password --flake .#<host> --root <MNT>`
   1. `umount -Rl <MNT>`
   1. `zpool export -a`
   1. Make sure to export the pools before reboot or you will see a message like, "The ZFS pool was last accessed by another system.".
      If you do forget, the pool can be imported manually after boot with `sudo zpool import -f <pool>`.
      It may take some time for the boot to finish because it will hang on importing a pool unsuccessfully.
1. Reboot

#### user setup

`home-manager` may not be available after bootstrap.
It can be run directly from the repository using `nix run`.

```shell-session
nix run github:nix-community/home-manager -- switch --flake .#<host>-<user>
```

[^1]: https://discourse.nixos.org/t/zfs-install-legacy-or-not/26047/2?u=djacu
