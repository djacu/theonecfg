# Configure nixd for option completion / hover / go-to-definition

## Background

By default, `nixd` does not know what nixpkgs to use or which module-system options to expose. It will work for lexical bindings (let-bound variables, function args, document symbols) but cannot resolve attribute paths like `services.openssh.enable` or `programs.claude-code.enable` — these aren't first-class variables, they're attrset paths merged at evaluation time.

To make nixd resolve option paths, it needs a configuration that points it at:

1. The nixpkgs to evaluate against, and
1. The module-system options to expose (NixOS, home-manager, etc.).

This is needed once per project, not globally. The Claude Code home-manager module already wires `nixd` as the LSP for `.nix` files; this runbook covers the per-project configuration on top of that.

## Recommended: per-project `.nixd.json`

`nixd` auto-discovers `.nixd.json` at the project root on startup. Drop a file like this at `/home/djacu/dev/djacu/theonecfg/.nixd.json`:

```json
{
  "nixpkgs": {
    "expr": "import (builtins.getFlake \"/home/djacu/dev/djacu/theonecfg\").inputs.nixpkgs-unstable {}"
  },
  "options": {
    "home-manager": {
      "expr": "(builtins.getFlake \"/home/djacu/dev/djacu/theonecfg\").homeConfigurations.\"malachite-djacu\".options"
    },
    "nixos": {
      "expr": "(builtins.getFlake \"/home/djacu/dev/djacu/theonecfg\").nixosConfigurations.<host>.options"
    }
  },
  "formatting": {
    "command": ["nixfmt"]
  }
}
```

Drop the `nixos` entry if not needed; substitute a real host name if you do want it. The `formatting.command` is optional — it lets nixd act as the LSP-side formatter for `textDocument/formatting`.

### Caveats

- **Absolute paths** in the JSON make this not directly committable. Two options:
  - Add `.nixd.json` to `.gitignore` and keep it as a per-machine file.
  - Generate it from the home-manager module, interpolating `config.home.homeDirectory` (and the host name) so each user/host gets a correct file. This couples nixd config to the home-manager rollout cycle.
- **First hit is slow.** First completion/hover triggers a full flake eval — typically 10–30s on a warm cache, much longer on a cold one. Cached after that.
- **Cache invalidation.** Editing `flake.nix` or anything reachable from the evaluated paths invalidates nixd's cache. Restart nixd to pick up the change: kill the running process (`pkill -f nixd`); Claude Code respawns it on the next LSP request.

### Verification

After dropping the file, in `claude` inside this repo:

- Open any `.nix` file (e.g. `home-modules/programs/claude/module.nix`).
- Ask: *"use nixd to show the type and default of `programs.claude-code.enable`"* (home-manager options) or *"...of `services.openssh.enable`"* (nixos options, requires the `nixos` entry).
- Should now resolve to the real option type and default. If you still get `Found 0 hover info`, check `~/.claude/debug/` for nixd init errors and confirm `pgrep -af nixd` shows the process running.

## Alternative: bake config into the home-manager module

The `programs.claude-code.lspServers.<name>` value in the home-manager unstable module is free-form JSON, so you *might* be able to pass `initializationOptions` directly from the module:

```nix
nix = {
  command = "${pkgs.nixd}/bin/nixd";
  extensionToLanguage = { ".nix" = "nix"; };
  initializationOptions = {
    nixpkgs.expr = "import <nixpkgs> {}";
    options.home-manager.expr = "...";
  };
};
```

This would apply to every project, not just one repo. Open question: I have not verified that Claude Code forwards `initializationOptions` in the LSP `initialize` request — the schema isn't documented for `lspServers`.

To check: set this in the module, rebuild + activate, and tail `~/.claude/debug/` for whether nixd reports the config as loaded. If it works, this becomes the global default and `.nixd.json` becomes unnecessary.

## Decision rule

- Just want option completion in *this* repo, willing to live with an absolute path: use `.nixd.json` per-project.
- Want option completion in *every* Nix project you touch with Claude, no per-repo file: try the `initializationOptions` route in the home-manager module, fall back to per-project files for any project where global config doesn't fit (e.g., a Nix project that uses a different nixpkgs channel than your global default).

## Related

- `home-modules/programs/claude/module.nix` — where `lspServers.nix` is wired.
- nixd upstream docs: https://github.com/nix-community/nixd/blob/main/docs/configuration.md
