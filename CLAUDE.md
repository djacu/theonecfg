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
