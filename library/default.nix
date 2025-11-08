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
    ;

  inherit (lib.fixedPoints)
    fix
    ;

  inherit (lib.lists)
    last
    map
    remove
    sort
    ;

  inherit (lib.strings)
    concatStringsSep
    match
    typeOf
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

    /**
      Join a parent path to one or more children.

      # Inputs

      `parent`

      : 1\. A parent path.

      `paths`

      : 2\. The paths to append.

      # Type

      ```
      joinParentToPaths :: Path -> String -> String
      joinParentToPaths :: Path -> [ String ] -> String
      ```

      # Examples
      :::{.example}
      ## `lib.path.joinParentToPaths` usage example

      ```nix
      joinParentToPaths ./home-modules "users"
      => /home/djacu/dev/djacu/theonecfg/home-modules/users
      joinParentToPaths ./home-modules [ "users" djacu" "module.nix" "]
      => /home/djacu/dev/djacu/theonecfg/home-modules/users/djacu/module.nix
      ```

      :::
    */
    joinParentToPaths =
      parent: paths:
      if typeOf paths == "string" then
        parent + ("/" + paths)
      else
        parent + ("/" + concatStringsSep "/" paths);

  });

  modules = fix (finalModules: {

    /**
      Make standalone home-manager modules for each user. Each attribute in the
      output will contain shared modules and user modules specific to that
      user. Each user must have a directory at the root of users directory.

      # Inputs

      `inputs`

      : 1.\ Flake inputs; the argument passed to flake outputs.

      `parentDirectory`

      : 2\. Path to all home-manager modules.

      `usersDirName`

      : 3\. Name of the users directory.

      # Type

      ```
      mkUserModules :: AttrSet -> Path -> String -> {<homeModule>}
      ```

      # Examples
      :::{.example}
      ## `lib.modules.mkUserModules` usage example

      ```nix
      mkUserModules inputs ./home-modules "users"
      => {
           djacu = {
             _module = { ... };
             imports = [
               "/nix/store/...-home-modules/users/djacu/module.nix"
               "/nix/store/...-home-modules/packages/module.nix"
               "/nix/store/...-home-modules/programs/module.nix"
               "/nix/store/...-home-modules/services/module.nix"
             ];
           };
           ucajd = {
             _module = { ... };
             imports = [
               "/nix/store/...-home-modules/users/ucajd/module.nix"
               "/nix/store/...-home-modules/packages/module.nix"
               "/nix/store/...-home-modules/programs/module.nix"
               "/nix/store/...-home-modules/services/module.nix"
             ];
           };
         }
      ```

      :::
    */
    mkUserModules =
      inputs: parentDirectory: usersDirName:
      let
        inherit (finalLibrary.path)
          joinParentToPaths
          getDirectoryNames
          ;

        usersDirectory = joinParentToPaths parentDirectory [ usersDirName ];
        usernames = getDirectoryNames usersDirectory;

        nonusers = pipe parentDirectory [
          getDirectoryNames
          (remove usersDirName)
        ];
        nonUserModules = map (flip pipe [
          (joinParentToPaths parentDirectory)
          (flip joinParentToPaths "module.nix")
        ]) nonusers;

      in
      genAttrs usernames (
        flip pipe [
          (joinParentToPaths usersDirectory)
          (flip joinParentToPaths "module.nix")
          (userModule: {
            imports = [ userModule ] ++ nonUserModules;
            _module.args = {
              inherit inputs;
            };
          })
        ]
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
