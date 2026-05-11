# theonecfg conventions

## Nix module style

- Prefer upstream modules over custom logic. Before writing a custom option, check whether `home-manager` or `nixpkgs` already exposes one.
- Use `lib.mkDefault`, `lib.mkIf`, and `lib.mkMerge` consistently with surrounding modules.
- Match the existing namespacing:
  - `theonecfg.programs.*` — shared programs (claude, fd, fish, tmux, zellij, nixvimcfg, ...).
  - `theonecfg.packages.*` — shared package bundles (admin, developer, networking, nix, ...).
  - `theonecfg.users.djacu.*` — user-specific overrides and extensions. Modules under `home-modules/users/djacu/programs/<name>/` override or extend the shared `theonecfg.programs.<name>` module.
- Standard module skeleton: declare `options.theonecfg.<path>.enable = mkEnableOption "..."`, then `config = mkIf cfg.enable { ... }`. Inherit `mkEnableOption` from `lib.options` and `mkIf` / `mkMerge` from `lib.modules` in a `let` block at the top.
- Auto-import: `home-modules/{programs,packages,services}/module.nix` and `home-modules/users/djacu/{programs,profiles}/module.nix` import every `<dir>/module.nix` under them automatically. New modules just need a `module.nix` at the right depth — no manual wiring in a parent file.

## Running nix commands inside the repo

Prefer the local flake's `legacyPackages` over going directly to `nixpkgs` for one-off `nix shell` / `nix run` / `nix build` invocations:

- ✅ `nix shell .#ripgrep -c rg ...`
- ✅ `nix run .#theonecfg.bootstrap-homelab-secrets -- scheelite`
- ❌ `nix shell --inputs-from . nixpkgs#ripgrep -c rg ...`

The `legacyPackages` output applies overlays (patches, overrides, custom packages) that the flake configures; going straight to `nixpkgs#` bypasses those. Only fall back to `--inputs-from . nixpkgs#<attr>` if a package isn't surfaced via `legacyPackages` (rare).
