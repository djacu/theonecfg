inputs:
let

  inherit (builtins)
    readDir
    tryEval
    ;

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    attrNames
    attrValues
    filterAttrs
    genAttrs
    removeAttrs
    ;

  inherit (lib.fixedPoints)
    fix
    ;

  inherit (lib.lists)
    last
    map
    sort
    ;

  inherit (lib.strings)
    match
    versionOlder
    ;

  inherit (lib.trivial)
    const
    flip
    pipe
    ;

in
fix (finalLibrary: {

  path = fix (finalPath: {

    /**
      Filter the contents of a directory path for directories only.

      # Inputs

      `contents`

      : 1\. The contents of a directory path.

      # Type

      ```
      filterDirectories :: AttrSet -> AttrSet
      ```

      # Examples
      :::{.example}
      ## `lib.path.filterDirectories` usage example

      ```nix
      x = {
        "default.nix" = "regular";
        djacu = "directory";
        programs = "directory";
        services = "directory";
      }
      filterDirectories x
      => {
        djacu = "directory";
        programs = "directory";
        services = "directory";
      }
      ```

      :::
    */
    filterDirectories = filterAttrs (const (fileType: fileType == "directory"));

    /**
      Get list of directories names under parent.

      # Inputs

      `path`

      : 1\. The parent path.

      # Type

      ```
      getDirectoryNames :: Path -> [String]
      ```

      # Examples
      :::{.example}
      ## `lib.path.getDirectoryNames` usage example

      ```nix
      getDirectoryNames ./home-modules
      => [
        "djacu"
        "programs"
        "services"
      ]
      ```
    */
    getDirectoryNames = flip pipe [
      finalPath.getDirectories
      attrNames
    ];

    /**
      Get attribute set of directories under parent.

      # Inputs

      `path`

      : 1\. The parent path.

      # Type

      ```
      getDirectories :: Path -> AttrSet
      ```

      # Examples
      :::{.example}
      ## `lib.path.getDirectories` usage example

      ```nix
      getDirectories ./home-modules
      => {
        djacu = "directory";
        programs = "directory";
        services = "directory";
      }
      ```
    */
    getDirectories = flip pipe [
      readDir
      finalPath.filterDirectories
    ];

    /**
      Join a path `prefix`, a middle segment `middle`, and a trailing segment
      `suffix` with “/”, producing an absolute path string.

      # Inputs

      `prefix`

      : 1\. A Nix path.

      `suffix`

      : 2\. A string that may itself be a subpath (e.g., "a/b.nix").

      `middle`

      : 3\. A string segment inserted between `prefix` and `suffix` that may be nested paths.

      # Type

      ```
      joinPathSegments :: Path -> String -> String -> String
      ```

      # Examples
      :::{.example}
      ## `lib.path.joinPathSegments` usage example

      ```nix
      joinPathSegments ./home-modules "module.nix" "programs"
      => "/nix/store/p8anp3wlicmsayagghjq7nrq61ycqafl-home-modules/programs/module.nix"
      # middle with subpath
      joinPathSegments ./home-modules "module.nix" "hardware/nvidia"
      "/nix/store/p8anp3wlicmsayagghjq7nrq61ycqafl-home-modules/hardware/nvidia/module.nix"
      # suffix with subpath
      joinPathSegments ./home-modules "zoxide/module.nix" "programs"
      => "/nix/store/p8anp3wlicmsayagghjq7nrq61ycqafl-home-modules/programs/zoxide/module.nix"
      ```

      :::
    */
    joinPathSegments =
      prefix: suffix: middle:
      "${prefix}/${middle}/${suffix}";

  });

  modules = fix (finalModules: {

    /**
      Get non-user directory names given a list of users and a path.

      # Inputs

      `users`

      : 1\. Known users whose directories will be filtered out in the return.

      `path`

      : 2\. Path to all home-manager modules.

      # Type

      ```
      getNonUsers :: [String] -> Path -> [String]
      ```

      # Example
      :::{.example}
      ## `lib.modules.getNonUsers` usage example

      ```nix
      getNonUsers [ "djacu" ] ./home-modules
      => { programs = "directory"; services = "directory"; }
      ```

      :::
    */
    getNonUsers =
      users: path:
      pipe path [
        readDir
        finalLibrary.path.filterDirectories
        (flip removeAttrs users)
        attrNames
      ];

    /**
      Make standalone home-manager modules for each user. Each attribute in the
      output will contain shared modules and user modules specific to that
      user. Each known user must have a directory at the root of `path` that
      matches the name given in users.

      # Inputs

      `users`

      : 1\. Known users for which to create home-manager modules.

      `path`

      : 2\. Path to all home-manager modules.

      # Type

      ```
      mkUserModules :: [String] -> Path -> {<homeModule>}
      ```

      # Examples
      :::{.example}
      ## `lib.modules.mkUserModules` usage example

      ```nix
      mkUserModules [ "djacu" "ucajd" ] ./home-modules
      => {
           djacu = {
             _module = { ... };
             imports = [
               "/nix/store/...-home-modules/djacu/module.nix"
               "/nix/store/...-home-modules/programs/module.nix"
               "/nix/store/...-home-modules/services/module.nix"
             ];
           };
           ucajd = {
             _module = { ... };
             imports = [
               "/nix/store/...-home-modules/ucajd/module.nix"
               "/nix/store/...-home-modules/programs/module.nix"
               "/nix/store/...-home-modules/services/module.nix"
             ];
           };
         }
      ```

      :::
    */
    mkUserModules =
      users: path:
      let
        nonUserModules = map (finalLibrary.path.joinPathSegments path "module.nix") (
          finalModules.getNonUsers users path
        );
      in
      genAttrs users (
        userName:
        let
          userModules = [ (finalLibrary.path.joinPathSegments path "module.nix" userName) ];
        in
        {
          imports = userModules ++ nonUserModules;
          _module.args = {
            inherit inputs;
          };
        }
      );

  });

  zfs = fix (finalZfs: {
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
        isUnstable = finalZfs.bootPackageIsUnstable args;
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
        && (finalZfs.kernelPackageIsNotBroken args kernelPackages)
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
          attrValues (finalZfs.compatibleKernelPackages args)
        )
      );
  });

})
