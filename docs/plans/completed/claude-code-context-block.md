# Persist Claude Code context rules via theonecfg

## Context

The user has an existing minimal home-manager module at `home-modules/programs/claude/module.nix` that just enables `programs.claude-code`. They want their working-principle rules persisted so they apply across Claude Code sessions instead of being re-typed every conversation.

We refined a set of context rules together (covering investigation, asking, implementation discipline, verification, sub-agents, and reporting) and identified that two of them — the Nix conventions specific to this repo — should not bleed into unrelated projects.

**Outcome:** Two CLAUDE.md files live in two places:
- Generic rules → `~/.claude/CLAUDE.md`, written by home-manager via the existing developer profile (inline `home.file`, no new module).
- Repo-specific Nix rules → `/home/djacu/dev/djacu/theonecfg/CLAUDE.md`, hand-committed to the repo.

## Final rule set

### Generic — for `~/.claude/CLAUDE.md`

```markdown
# Working principles

## Investigation
- Don't act on unverified inference about how a system or its dependencies behave. Validate via source code, documentation, or testing. State explicitly when operating on inference and what would invalidate the assumption.
- When investigating, iterate until a pass discovers nothing new. Before acting, explicitly list any remaining assumptions and the risk if each is wrong.
- Distinguish "code compiled / typechecked" from "feature works." Be explicit about what was actually exercised end-to-end vs. only statically validated.

## Asking and deciding
- Ask the user when (a) the answer would materially change the approach, (b) the action is hard to reverse, or (c) more than one reasonable interpretation of intent exists. For low-stakes ambiguity, pick a default, state it explicitly, and proceed.
- When picking a default in an ambiguous case, name the choice and the alternative rejected in one line.

## Implementation discipline
- Don't refactor, rename, or clean up adjacent code unless explicitly asked. A bug fix doesn't need surrounding improvements.
- No speculative abstractions. Don't extract helpers, add config options, or design for hypothetical futures. Three similar lines beats a premature abstraction.
- No defensive code at internal boundaries. Don't add validation or fallbacks for cases that can't happen. Trust internal callers; only validate at system boundaries.

## Verification after changes
- After every edit, read the final file region to confirm the result matches intent. This catches Edit applying to the wrong location.
- Run the project's own checks (lint, typecheck, tests, build) before declaring done. Don't claim success on the basis of "the edit applied cleanly."

## Sub-agents
- Don't trust a sub-agent's report. Verify the artifact directly: read the file the agent claims to have edited; re-run the command the agent claims passed. Flag vague claims and unstated uncertainty.
- Brief sub-agents on constraints, not just goals. Tell them what NOT to do (don't expand scope, don't add comments, don't create helpers) — they don't inherit these rules.

## Reporting
- End each task with: what changed / what's still open / what was not verified. No padding.
```

### Repo-specific — for `/home/djacu/dev/djacu/theonecfg/CLAUDE.md`

```markdown
# theonecfg conventions

## Nix module style
- Prefer upstream modules over custom logic. Before writing a custom option, check whether home-manager or nixpkgs already exposes it.
- Use `lib.mkDefault`, `lib.mkIf`, and `lib.mkMerge` consistently with surrounding modules.
- Match the existing namespacing:
  - `theonecfg.programs.*` — shared programs (claude, fd, fish, tmux, zellij, ...).
  - `theonecfg.packages.*` — shared package bundles (admin, developer, networking, nix, ...).
  - `theonecfg.users.djacu.*` — user-specific overrides and extensions.
  Modules under `home-modules/users/djacu/programs/<name>/` override or extend the shared `theonecfg.programs.<name>` module.
- Standard module skeleton: `options.theonecfg.<path>.enable = mkEnableOption "..."`; then `config = mkIf cfg.enable { ... }`. Inherit `mkEnableOption` from `lib.options` and `mkIf`/`mkMerge` from `lib.modules` in a `let` block.
- Auto-import: `home-modules/{programs,packages,services}/module.nix` and `home-modules/users/djacu/{programs,profiles}/module.nix` import every `<dir>/module.nix` under them automatically. New modules just need a `module.nix` at the right depth — no manual wiring.
```

## Files to change

### 1. `home-modules/users/djacu/profiles/developer/module.nix` — extend

Add one `home.file` entry inside the existing `config` block (after the `theonecfg.programs.*` and `theonecfg.packages.*` toggles). The block lives behind `mkIf (cfg.enable && cfg.profiles.developer.enable)`, so the file only lands when the developer profile is active.

```nix
home.file.".claude/CLAUDE.md".text = ''
  # Working principles
  ... (full generic rule content from above) ...
'';
```

Reasons this is the right home rather than the shared `home-modules/programs/claude/module.nix`:
- Content is djacu-specific, the shared module is meant to be reusable.
- The developer profile is already user-namespaced (`home-modules/users/djacu/profiles/developer/`), so the user-personal content is in the right namespace.
- No new files, no new options. Matches the "no speculative abstractions" rule.

### 2. `/home/djacu/dev/djacu/theonecfg/CLAUDE.md` — create

Hand-write the repo-specific Nix rules as shown above. Commit it. Not generated by home-manager — it lives with the source it describes.

### 3. `home-modules/programs/claude/module.nix` — leave as-is

No changes. Just installs `programs.claude-code`.

## Verification

After applying:

1. **Build the home config:**
   ```
   nix build .#homeConfigurations.argentite-djacu.activationPackage
   ```
   (Adjust the attribute name to match the actual `homeConfigurations` output — confirm via `nix flake show` if uncertain.)

2. **Activate (or rebuild if running on argentite):**
   ```
   home-manager switch --flake .#argentite-djacu
   ```

3. **Confirm the user-level file landed:**
   ```
   cat ~/.claude/CLAUDE.md
   readlink ~/.claude/CLAUDE.md   # should point into /nix/store
   ```

4. **Confirm the project-level file is committed:**
   ```
   git ls-files CLAUDE.md
   ```

5. **End-to-end test:** start a new Claude Code session inside `/home/djacu/dev/djacu/theonecfg`. Both files should be auto-loaded into context (visible in `/context` or by asking Claude what rules it's operating under).

## Out of scope (deferred)

- A NixOS-level module for claude-code. The user mentioned this as a future goal but the current request is to extend the existing home-manager setup. Defer until after this lands.
- Programmatic option for CLAUDE.md content (`userMemory` attr, etc.). Skipped per the user's preference for the simplest wiring; can be promoted later if a second user or per-project rule sets emerge.
