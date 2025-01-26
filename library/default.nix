inputs:
let
  inherit (builtins)
    attrValues
    match
    tryEval
    ;

  inherit (inputs.nixpkgs-unstable)
    lib
    ;

  inherit (lib.attrsets)
    filterAttrs
    ;

  inherit (lib.lists)
    last
    sort
    ;

  inherit (lib.strings)
    versionOlder
    ;
in
{
  zfs = rec {
    /**
      Check if the defined ZFS package for boot is unstable.

      # Inputs

      `args`

      : A set of a package set, `pkgs`, and a module configuration, `config`.

      # Type
      ```
      bootPackageIsUnstable :: AttrSet -> Bool
      ```
    */
    bootPackageIsUnstable = args: args.config.boot.zfs.package == args.pkgs.zfsUnstable;

    /**
      Check that ZFS kernel package is not broken.

      # Inputs

      `args`

      : A set of a package set, `pkgs`, and a module configuration, `config`.

      `kernelPackages`

      : A set of kernel packages.

      # Type
      ```
      kernelPackageIsNotBroken :: AttrSet -> AttrSet -> Bool
      ```
    */
    kernelPackageIsNotBroken =
      args: kernelPackages:
      let
        isUnstable = bootPackageIsUnstable args;
      in
      (!isUnstable && !kernelPackages.zfs.meta.broken)
      || (isUnstable && !kernelPackages.zfs_unstable.meta.broken);

    /**
      Get all linux kernel packages that are compatible with ZFS.

      # Inputs

      `args`

      : A set of a package set, `pkgs`, and a module configuration, `config`.

      # Type
      ```
      compatibleKernelPackages :: AttrSet -> AttrSet
      ```
    */
    compatibleKernelPackages =
      args:
      filterAttrs (
        name: kernelPackages:
        (match "linux_[0-9]+_[0-9]+" name) != null
        && (tryEval kernelPackages).success
        && (kernelPackageIsNotBroken args kernelPackages)
      ) args.pkgs.linuxKernel.packages;

    /**
      Get the latest linux kernel that is compatible with ZFS.
      Note this might jump back and forth as kernel get added or removed.

      Note: This function and the ones it calls were lifted from the following and modified.
      https://github.com/nix-community/srvos/blob/2fa72cea3d3d15b104f3c69de18316ef575bc837/nixos/mixins/latest-zfs-kernel.nix

      # Inputs

      `args`

      : A set of a package set, `pkgs`, and a module configuration, `config`.

      # Type
      ```
      latestKernelPackage :: AttrSet -> AttrSet
      ```
    */
    latestKernelPackage =
      args:
      last (
        sort (a: b: (versionOlder a.kernel.version b.kernel.version)) (
          attrValues (compatibleKernelPackages args)
        )
      );
  };
}
