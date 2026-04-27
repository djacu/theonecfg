# Plan: Extend `theonecfg.programs.claude` with MCP and LSP

## Context

`home-modules/programs/claude/module.nix` currently only enables `programs.claude-code` and sets `context`. The user wants Claude Code configured for their day-to-day languages (**Nix, Rust, C++, Go, frontend, Python, Java, Linux admin**) by adding:

1. The `mcp-nixos` MCP server, since they're a Nix power user. Other MCPs from `modelcontextprotocol/servers` are skipped — upstream describes them as reference implementations.
2. Declarative LSP integration via `programs.claude-code.lspServers` for fifteen language servers.

Skills are deferred to a later round per user direction.

All four hosts (`argentite`, `cassiterite`, `malachite`, `scheelite`) pin `release = "unstable"`, so the unstable-only options (`lspServers`, `mcpServers` via plugin-dir) are safe to use without backward-compat shims.

The user has the **official Anthropic plugin marketplace** at `~/.claude/plugins/marketplaces/claude-plugins-official/`, but the `*-lsp` "plugins" inside are documentation stubs only — no `.claude-plugin/`, no `.lsp.json`, no actual integration. So real LSP integration must come from Nix. OAuth-authenticated MCPs (Notion, Google Drive, Atlassian Rovo, Slack) are tracked in `~/.claude/mcp-needs-auth-cache.json` — leave alone.

User has zero LSPs in PATH today (`developer/module.nix` deliberately ships no compilers/LSPs). All LSP packages will be referenced by absolute Nix store path so we don't pollute PATH.

### What LSPs buy Claude Code

Semantic go-to-definition, find-references, hover/type info, diagnostics, document/workspace symbols, and rename refactor — all anchored in real compiler/typechecker output rather than text grep. Highest payoff inside properly-configured projects (`Cargo.toml`, `go.mod`, `tsconfig.json`, `flake.nix`, `compile_commands.json`); little benefit for standalone files.

## Architecture decisions

- **Single `enable` option** per existing project convention (`fish`, `tmux`, `fd` follow the same pattern).
- **LSP commands by absolute store path** (e.g. `${pkgs.gopls}/bin/gopls`) — preserves the "no compilers in user profile" stance from `home-modules/packages/developer/module.nix`.
- **C/C++ handled in one entry** — `clangd` covers both via `extensionToLanguage` mapping.
- **Python LSP defaults to `basedpyright`** — a maintained, faster-updating fork of `pyright`. Trivially swappable.
- **Skip `marketplaces`, `plugins`, `skills`** — not requested in this round.

## Files

### MODIFIED — `home-modules/programs/claude/module.nix`

Keep the existing options + `context` block. Inside the existing `mkIf cfg.enable` config block, add:

1. **`programs.claude-code.mcpServers.nixos`**
   - `type = "stdio";`
   - `command = "${pkgs.mcp-nixos}/bin/mcp-nixos";`

   Verified: `pkgs.mcp-nixos` 2.3.1 exists in `nixpkgs-unstable`.

2. **`programs.claude-code.lspServers`** — fifteen entries, all using absolute store paths:

   | Key            | Command                                                                | Args               | extensionToLanguage                                                                                                  |
   | -------------- | ---------------------------------------------------------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------- |
   | `nix`          | `${pkgs.nixd}/bin/nixd`                                                | (none)             | `.nix` → `nix`                                                                                                       |
   | `rust`         | `${pkgs.rust-analyzer}/bin/rust-analyzer`                              | (none)             | `.rs` → `rust`                                                                                                       |
   | `cpp`          | `${pkgs.clang-tools}/bin/clangd`                                       | (none)             | `.c`/`.h` → `c`; `.cc`/`.cpp`/`.cxx`/`.hh`/`.hpp` → `cpp`                                                            |
   | `go`           | `${pkgs.gopls}/bin/gopls`                                              | `[ "serve" ]`      | `.go` → `go`                                                                                                         |
   | `typescript`   | `${pkgs.vtsls}/bin/vtsls`                                              | `[ "--stdio" ]`    | `.ts`/`.tsx`/`.js`/`.jsx` → `typescript`/`typescriptreact`/`javascript`/`javascriptreact`                            |
   | `tailwind`     | `${pkgs.tailwindcss-language-server}/bin/tailwindcss-language-server`  | `[ "--stdio" ]`    | `.html`/`.tsx`/`.jsx` → `html`/`typescriptreact`/`javascriptreact` (Tailwind treats class attrs context-sensitively) |
   | `python`       | `${pkgs.basedpyright}/bin/basedpyright-langserver`                     | `[ "--stdio" ]`    | `.py`/`.pyi` → `python`                                                                                              |
   | `java`         | `${pkgs.jdt-language-server}/bin/jdtls`                                | (none)             | `.java` → `java`                                                                                                     |
   | `bash`         | `${pkgs.bash-language-server}/bin/bash-language-server`                | `[ "start" ]`      | `.sh`/`.bash` → `shellscript`                                                                                        |
   | `yaml`         | `${pkgs.yaml-language-server}/bin/yaml-language-server`                | `[ "--stdio" ]`    | `.yml`/`.yaml` → `yaml`                                                                                              |
   | `html`         | `${pkgs.vscode-langservers-extracted}/bin/vscode-html-language-server` | `[ "--stdio" ]`    | `.html`/`.htm` → `html`                                                                                              |
   | `css`          | `${pkgs.vscode-langservers-extracted}/bin/vscode-css-language-server`  | `[ "--stdio" ]`    | `.css`/`.scss`/`.less` → `css`/`scss`/`less`                                                                         |
   | `json`         | `${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server` | `[ "--stdio" ]`    | `.json`/`.jsonc` → `json`/`jsonc`                                                                                    |
   | `toml`         | `${pkgs.taplo}/bin/taplo`                                              | `[ "lsp" "stdio" ]`| `.toml` → `toml`                                                                                                     |
   | `markdown`     | `${pkgs.marksman}/bin/marksman`                                        | `[ "server" ]`     | `.md`/`.markdown` → `markdown`                                                                                       |

   (15 entries — `vscode-langservers-extracted` surfaces three LSPs from one package. `tailwind` and `html` overlap on `.html`; that's fine — Claude Code can run multiple LSPs against the same file.)

3. **Drop the dead commented-out block** at the bottom of the file (lines 59–64): the `# home.packages = [ pkgs.claude-code pkgs.mcp-nixos ];` block.

Sketch of the resulting module shape:

```nix
{ config, lib, pkgs, ... }:
let
  inherit (lib.options) mkEnableOption;
  inherit (lib.modules) mkIf;
  cfg = config.theonecfg.programs.claude;
in
{
  options.theonecfg.programs.claude.enable = mkEnableOption "claude package config";

  config = mkIf cfg.enable {
    programs.claude-code = {
      enable = true;
      context = ''...''; # unchanged

      mcpServers.nixos = {
        type = "stdio";
        command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
      };

      lspServers = { /* 15 entries per the table */ };
    };
  };
}
```

### Files NOT touched

- `flake.nix` / `flake.lock` — every package referenced (`mcp-nixos`, all 12 LSP packages) is in `nixpkgs-unstable` already.
- `home-modules/packages/developer/module.nix` — LSPs go to Claude Code via store paths, not PATH.
- `home-modules/users/djacu/profiles/developer/module.nix` — already enables `theonecfg.programs.claude`.
- `home-configurations/*` — no per-host changes.
- `package-sets/top-level/` — nothing added (skills are deferred).
- `~/.claude/` user-managed files (`.credentials.json`, `policy-limits.json`, `mcp-needs-auth-cache.json`, marketplace state) — out of scope; leave alone.

## Verification

1. **Format** — `nix fmt`.
2. **Eval** — `nix flake check .` to catch eval errors across all four `homeConfigurations`.
3. **Build** — e.g. `nix build .#homeConfigurations."malachite-djacu".activationPackage` to confirm the wrapped `claude` builds.
4. **Inspect wrapper** — `cat $(readlink -f result)/home-files/.nix-profile/bin/claude` should show `--plugin-dir /nix/store/...claude-code-hm-plugin/`. Inside that plugin dir: `.claude-plugin/plugin.json`, `.mcp.json` (with `nixos` server), `.lsp.json` (with 15 servers).
5. **Activate** — `home-manager switch --flake .#malachite-djacu`.
6. **Interactive checks**:
   - `claude` → `/mcp` → confirm `nixos` is connected. Ask "describe `services.openssh`"; verify it queries the MCP rather than guessing.
   - Open a `.rs` / `.go` / `.nix` / `.ts` / `.cpp` / `.py` / `.sh` / `.yaml` / `.toml` / `.md` file in a project with the LSP's project markers and confirm Claude can use LSP-backed tools (`lspServers` only takes effect inside such projects).
7. **Idempotence** — re-run `home-manager switch`; should be a no-op.

## Open items intentionally deferred

### Skills — full design (recorded for the follow-up round)

**Why deferred:** keeps this change tight and focused on MCP + LSP. Skills can be added cleanly on top of this plan with no rework needed below.

**What we would have done:**

1. **NEW — `package-sets/top-level/anthropic-skills.nix`**

   ```nix
   { fetchFromGitHub }:
   fetchFromGitHub {
     owner = "anthropics";
     repo = "skills";
     rev = "<commit-sha>";    # nix-prefetch-github at the time of authoring
     hash = "sha256-...";
   }
   ```

   Auto-exposed as `pkgs.anthropic-skills` by the existing overlay (`overlays/default.nix:48-54` runs `packagesFromDirectoryRecursive` against this directory). No flake input needed.

2. **NEW — `home-modules/programs/claude/skills/.gitkeep`**

   Empty placeholder so the directory exists in git and `builtins.readDir ./skills` evaluates cleanly with no user-authored skills present.

3. **MODIFIED — `home-modules/programs/claude/module.nix`**

   Add `lib.attrsets` inherits (`mapAttrs'`, `nameValuePair`, `filterAttrs`) and a `let` block computing local skills:

   ```nix
   skillsRoot = ./skills;
   localSkills = mapAttrs'
     (name: _: nameValuePair name "${skillsRoot}/${name}")
     (filterAttrs (_: type: type == "directory") (builtins.readDir skillsRoot));
   ```

   Then add to the `programs.claude-code` block:

   ```nix
   skills = {
     mcp-builder = "${pkgs.anthropic-skills}/skills/mcp-builder";
   } // localSkills;
   ```

   Result: `~/.claude/skills/mcp-builder/` symlinks into the nix store; every subdirectory under `home-modules/programs/claude/skills/` becomes its own skill named after the directory.

**Why these choices over alternatives:**

- **`skills` over `marketplaces`** — `marketplaces` only registers the source in `~/.claude/plugins/known_marketplaces.json`; activating individual skills still requires interactive `/plugin install`. `skills` is fully declarative.
- **`skills` over `plugins`** — verified that `anthropics/skills` is a *marketplace* (top-level `.claude-plugin/` contains only `marketplace.json`) and individual skills under `skills/<name>/` don't have per-skill `.claude-plugin/`. So `plugins` cannot select just `mcp-builder`; it would only work for whole-repo plugins.
- **`pkgs.anthropic-skills` via overlay over a flake input** — matches the project's existing pattern in `package-sets/top-level/`. A new flake input would be heavier and isn't needed since pinning via `fetchFromGitHub` rev+hash is sufficient.
- **Auto-discovery of local skills via `builtins.readDir`** — matches the project's auto-import philosophy in `home-modules/{programs,packages,services}/module.nix`. Adding a new local skill requires only `mkdir home-modules/programs/claude/skills/<name>` + write `SKILL.md`; no module edit.
- **Single `skills` attrset combining upstream + local** — required by the unstable HM module schema, where `skills` is `either (attrsOf X) path` at the top level. Mixing pinned-upstream paths and local paths inside one attrset is the supported pattern (per the upstream example with `beads = "${pkgs.beads.src}/...";`).

**Pinned skill list:** just `mcp-builder` (helps Claude scaffold a custom MCP server should the user later want to write one). `frontend-design` was considered and dropped in this round; can be added with a one-line attr addition.

### Other deferrals

- Other MCPs from `modelcontextprotocol/servers` (`memory`, `filesystem`, `git`, `time`, `fetch`, `sequential-thinking`) — user opted out per upstream's "reference implementation" caveat.
- `marketplaces`, declared `plugins`, `rules`, `outputStyles`, `agents`, `commands`, custom `hooks` — not requested.
- Picking `nil` over `nixd`, `pyright` over `basedpyright`, or `typescript-language-server` over `vtsls`. Defaults chosen are the more featureful options; trivially swappable later.
