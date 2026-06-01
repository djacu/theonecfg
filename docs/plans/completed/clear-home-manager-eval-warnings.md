# Clear home-manager eval warnings

## Context

`nix run .#verify-hydra-home-configs` surfaces two warnings repeated for
each home-configuration after the recent input bump:

1. `programs.ssh.matchBlocks` is deprecated in home-manager 26.11; the
   replacement is `programs.ssh.settings`. Only call site in this repo:
   `home-modules/users/djacu/programs/gpg/module.nix:142-156`.

2. Home-manager master (26.11) and `nixpkgs-unstable` (26.05) report
   different release cycles. This is a transient channel-transition skew:
   the `nixos-unstable` channel hasn't rolled forward to 26.11pre yet but
   home-manager master already has. Verified — `pkgs.lib.trivial.release`
   currently evaluates to `"26.05"` and the home-manager input's
   `release.json` reports `"26.11"`.

We want both warnings cleared, and for the version-skew suppression to be
self-clearing the moment nixpkgs catches up.

## Changes

### 1. `home-modules/users/djacu/programs/gpg/module.nix`

Migrate `programs.ssh.matchBlocks` → `programs.ssh.settings` (lines 142-156).
The new `settings` option is a freeform `attrsOf anything` keyed by upstream
OpenSSH directive names (`<home-manager>/modules/programs/ssh.nix:649`),
whereas `matchBlocks` used hm-flavored typed sub-options. So this is *not*
a pure rename — every option key has to be translated to its OpenSSH
equivalent: `forwardAgent` → `ForwardAgent`, `addKeysToAgent` →
`AddKeysToAgent`, `compression` → `Compression`, `serverAliveInterval` →
`ServerAliveInterval`, `serverAliveCountMax` → `ServerAliveCountMax`,
`hashKnownHosts` → `HashKnownHosts`, `userKnownHostsFile` →
`UserKnownHostsFile`, `controlMaster` → `ControlMaster`, `controlPath` →
`ControlPath`, `controlPersist` → `ControlPersist`, `hostname` →
`HostName`, `remoteForwards` → `RemoteForward`.

Rendering: `directiveRenderers` (`ssh.nix:466-475`) provides custom
renderers for special directives (`LocalForward`/`RemoteForward`/
`DynamicForward`/`SetEnv` plus the comma/space-list ones). Every other
key falls through to a catch-all that calls `toString` on the value
(`sshDirectiveStrWithIndent`, `ssh.nix:477-485`). That catch-all is what
made the first (rename-only) attempt fail: a lowercase `remoteForwards`
isn't in `directiveRenderers`, so each `{ bind = ...; host = ...; }`
record got `toString`'d → `cannot coerce a set to a string`. Using the
proper directive name `RemoteForward` routes through `renderForward`
(`ssh.nix:427-428`), which handles the `{ bind; host; }` shape natively,
so the `RemoteForward` entries carry over unchanged.

`extraOptions` isn't used in this module, so the secondary
"extraOptions deprecated" caveat doesn't apply.

### 2. `home-modules/users/djacu/module.nix`

Add to the `config = mkIf cfg.enable { ... }` block:

```nix
home.enableNixpkgsReleaseCheck = false;
warnings = lib.optional (lib.versionAtLeast pkgs.lib.trivial.release "26.11") ''
  nixpkgs has caught up to home-manager (now ${pkgs.lib.trivial.release}).
  Drop `home.enableNixpkgsReleaseCheck = false` from
  home-modules/users/djacu/module.nix — the workaround is no longer needed.
'';
```

The file currently lists `lib` and `theonecfg` in its function args but not
`pkgs`; `pkgs` needs to be added to the args.

Justification for the location: djacu is the only home-manager user across
all four host home-configurations, and this module's `config` block is
already gated by `theonecfg.users.djacu.enable` (which every host sets
true). Putting both lines here is one edit that covers every config.

Why a `warnings` entry and not `lib.warn`: the upstream `warnings` module
option flows through `config.warnings` and prints at eval time the same
way the deprecation messages we just cleared did. It's the same surface
the user already monitors via `nix run .#verify-hydra-home-configs`.

## Critical files

- `home-modules/users/djacu/programs/gpg/module.nix` — only file using
  `programs.ssh.matchBlocks`.
- `home-modules/users/djacu/module.nix` — shared djacu home-manager entry.

## Verification

```bash
nix run .#verify-hydra-home-configs
```

(or the equivalent `nix-eval-jobs --flake .#hydraJobs.homeConfigs.x86_64-linux`
invocation).

Expected: no `programs.ssh.matchBlocks ... is deprecated` warning, no
`Home Manager version 26.11 and Nixpkgs version 26.05` warning. The
self-clearing reminder stays silent until `pkgs.lib.trivial.release` ≥
"26.11".

## Commits

Following the repo convention seen in `homeModules.theonecfg.packages.productivity: add glow`:

- `homeModules.theonecfg.users.djacu.programs.gpg: migrate programs.ssh.matchBlocks to settings`
- `homeModules.theonecfg.users.djacu: suppress HM/nixpkgs release check with self-clearing guard`
