# theonecfg

## architecture

### formatter

Formatter setup to use for the repository.

### home-configurations

Home-manager configurations for a combination of host and user.
They are accessed via `homeConfigurations.<host>-<user>` attributes.

### home-modules

Home-manager modules under `theonecfg` namespace gated behind `enable` options.
Modules are grouped in directories by `programs`, `services`, or a `<user>`.
Modules created for one user are not available to another user to enable.
Modules not under a `<user>` directory are available for all users to define.
See `mkUserModules` for details about how modules are filtered.
They are accessed via `homeConfigurations.<user>` attributes.

### legacy-packages

A nixpkgs package set with `theonecfg` overlays applied.

### nixos-configurations

NixOS configurations for a host.
They are accessed via `nixosConfigurations.<host>`.

### nixos-modules

NixOS modules under `theonecfg` namespace gated behind `enable` options.
There is currently little structure here except for user specific modules which are in directories.

### overlays

Centralized overlays to be used elsewhere in `theonecfg`.
Pulls in external overlays from inputs.
Pulls in internal overlays from directories in the `overlays` directory that have a `package.nix` file.
Currently used in `legacy-packages`, `nixos-modules`, and `home-configurations`.

### packages

Packages that can be built or run.

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
   1. `cd nixos-configurations/scheelite`
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

`nix run github:nix-community/home-manager -- switch --flake .#<host>-<user>`

[^1]: https://discourse.nixos.org/t/zfs-install-legacy-or-not/26047/2?u=djacu
