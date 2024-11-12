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
