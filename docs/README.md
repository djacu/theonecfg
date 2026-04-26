# docs/

This directory contains all project documentation for the theonecfg NixOS configuration repository. It is organized into subdirectories by document type.

## Search exclusion

This directory is listed in the repository's `.ignore` file. Tools that respect `.ignore` (ripgrep, fd, Telescope `live_grep`) will skip this directory by default. To explicitly search within docs, use the `--no-ignore` flag.

## Directory structure

```
docs/
├── README.md              # This file
├── decisions/             # Architecture Decision Records
├── investigations/        # Research and deep-dive findings
├── plans/
│   ├── active/            # Plans currently being worked on
│   └── completed/         # Finished plans, kept for reference
├── reference/             # Standing reference material
├── reports/               # Session reports and summaries
├── runbooks/              # Step-by-step operational procedures
└── troubleshooting/       # Known issues and their solutions
```

## Directory descriptions

### decisions/

Architecture Decision Records (ADRs). Use this directory to document significant technical choices and the reasoning behind them. Each document should capture the context, the options considered, the decision made, and why. These are valuable when revisiting past choices or onboarding someone new to the project.

**Example topics:** choosing a filesystem layout, selecting a NixOS release channel strategy, deciding how to structure flake inputs.

### investigations/

Research and deep-dive findings. Use this directory when exploring a topic in depth before making a decision or taking action. Investigations may or may not lead to changes in the codebase. They capture what was learned, even if the conclusion is "no action needed."

**Example topics:** evaluating whether to switch from ZFS to btrfs, researching NixOS module system patterns, comparing secret management approaches.

### plans/

Implementation plans, split into two subdirectories:

- **active/** - Plans that are currently being worked on. A plan describes what will be changed, why, and the steps to get there. Move plans here when work begins.
- **completed/** - Plans that have been fully implemented. Move plans from `active/` to `completed/` when the work is done. Keep them for historical reference.

**Example topics:** migrating all machines to systemd stage 1, adding a new machine to the fleet, refactoring the user module system.

### reference/

Standing reference material that does not fit neatly into another category. This includes information that is useful to have on hand but is not tied to a specific decision, investigation, or task. Content here tends to be stable and updated infrequently.

**Current contents:**

- `ores.md` - Ore naming reference (machine naming conventions)
- `stones.md` - Stone naming reference (machine naming conventions)

### reports/

Session reports and summaries. Use this directory to document what was done during a work session, including the problem encountered, the solution applied, verification steps, and any outstanding follow-up work. Reports are a record of completed work.

**Example topics:** fixing a build failure, migrating a configuration option, debugging a boot issue.

### runbooks/

Step-by-step operational procedures. Use this directory for repeatable processes that someone (human or agent) may need to follow in the future. Runbooks should be concrete and actionable, with commands and expected outputs where applicable.

**Example topics:** how to add a new machine to the fleet, how to deploy a configuration to scheelite, how to recover from a failed ZFS import, how to update flake inputs.

### troubleshooting/

Known issues and their solutions. Use this directory to document problems that have been encountered and resolved, so they can be quickly addressed if they recur. Each document should describe the symptoms, the root cause, and the fix.

**Example topics:** `nix flake show` assertion failures, ZFS pool import failures during boot, home-manager activation errors.

## Conventions

- All documents are Markdown files (`.md`).
- Use descriptive filenames in kebab-case (e.g., `zfs-rollback-migration.md`).
- Include a date and status at the top of reports, investigations, and plans.
- When a document references specific files in the repository, use paths relative to the repository root (e.g., `nixos-configurations/scheelite/default.nix`).
