# Stash scheduled maintenance — Design

> Design phase. Implementation plan to be added below via `superpowers:writing-plans`.

## Goal

Add a daily scheduled task on scheelite that fires Stash's full library maintenance pipeline — Scan, Identify, Auto Tag, Generate, Clean — against Stash's local GraphQL endpoint. Currently each task must be run manually through Stash's UI (Settings → Tasks, requires Advanced Mode toggle); new content imported by Whisparr never gets indexed or identified without user intervention. This closes that loop.

## Architecture

A NixOS module extension to `theonecfg.services.stash` that wires:

- New options namespace `scheduledMaintenance` (`enable`, `schedule`).
- `systemd.timers.stash-maintenance` firing on `OnCalendar`.
- `systemd.services.stash-maintenance` (oneshot) that POSTs 5 GraphQL mutations against Stash's local endpoint.
- A `pkgs.writeShellApplication` script that reads Stash's API key from sops, issues each mutation in sequence, and checks each response for GraphQL errors.

Stash's internal task queue serializes the actual work. The 5 mutations enqueue jobs near-instantly; Stash then runs them serially via its single-worker task runner. So Scan completes before Identify even starts, even though both are queued at the same time from our script's perspective.

## Option surface

```nix
scheduledMaintenance = {
  enable = mkEnableOption "Daily Stash library maintenance (scan + identify + auto tag + generate + clean)";
  schedule = mkOption {
    type = str;
    default = "*-*-* 03:00:00";
    description = ''
      systemd OnCalendar expression for when the maintenance pipeline fires.
      Default is 03:00 local time, daily.
    '';
  };
};
```

Defaults: disabled (opt-in per repo convention). Schedule: 03:00 daily.

## Components (additions to `nixos-modules/services/stash/module.nix`)

1. **Maintenance request bodies** in the `let` block, computed at module-eval time via `builtins.toJSON`:
   - `identifyBody` — uses GraphQL variables for `sources`, populated from `cfg.stashBoxes`. Cleaner than concatenating sub-documents into the query string.
   - `simpleBody mutation` — helper for the four no-arg mutations.
   - `scanBody`, `autoTagBody`, `generateBody`, `cleanBody` — derived from `simpleBody`.

2. **`stashMaintenance` script** (`pkgs.writeShellApplication`):
   - Reads `cfg.apiKeyFile` at runtime (sops-managed path).
   - `post` helper: `curl -fsS --max-time 30 -X POST` to `http://127.0.0.1:${cfg.port}/graphql` with `Content-Type: application/json` and `ApiKey: <key>` headers. Checks response body for `.errors` via `jq -e`; logs the returned job ID on success.
   - Issues 5 mutations in declared sequence: scan, identify, autotag, generate, clean.
   - `writeShellApplication` provides `errexit/nounset/pipefail` automatically — no `set` line needed.

3. **Assertion**: `scheduledMaintenance.enable` requires `cfg.apiKeyFile != null`. Without the API key, Stash's GraphQL refuses mutations and the script would also fail on its own `[ -r null ]` test. An eval-time assertion gives a clear error message at `nix build` rather than a confusing runtime failure.

4. **`systemd.timers.stash-maintenance`** (gated by `mkIf cfg.scheduledMaintenance.enable`):
   - `OnCalendar = cfg.scheduledMaintenance.schedule`
   - `Persistent = true` — fires on next boot if scheelite was off at the scheduled time.
   - `wantedBy = [ "timers.target" ]`

5. **`systemd.services.stash-maintenance`** (gated by `mkIf cfg.scheduledMaintenance.enable`):
   - `Type = "oneshot"`
   - `after = requires = [ "stash.service" ]` — wait for Stash; fail visibly if Stash isn't up. Rather than silently skip.
   - Runs as root (no `User=`). Matches the convention used by `mkArrApiPushService` and similar oneshots already in the repo.
   - `ExecStart = ${stashMaintenance}/bin/stash-maintenance`

The whole maintenance plumbing is also implicitly gated by the outer `mkIf cfg.enable (mkMerge [...])` — if Stash itself isn't enabled, the maintenance units aren't even declared.

## Host enablement (`nixos-configurations/scheelite/default.nix`)

One line added to the existing `theonecfg.services.stash` block:

```nix
scheduledMaintenance.enable = true;
```

Schedule defaults to 03:00 daily; override only if a different time is desired.

## Data flow

```
[ timer fires at 03:00 ]
   │
   ▼
[ stash-maintenance.service starts ]
   │  (after stash.service active)
   ▼
[ stash-maintenance script reads cfg.apiKeyFile ]
   │
   ├──► POST /graphql metadataScan(input: {})         → job queued
   ├──► POST /graphql metadataIdentify(sources: …)    → job queued
   ├──► POST /graphql metadataAutoTag(input: {})      → job queued
   ├──► POST /graphql metadataGenerate(input: {})     → job queued
   └──► POST /graphql metadataClean(input: {})        → job queued
   │
   ▼
[ script exits 0; unit shows "active (exited)" ]

[ Stash's internal task runner executes the 5 queued jobs serially ]
   scan → identify → autotag → generate → clean
```

## Error handling

- **Stash not running** → unit fails on the `requires=` dependency; `systemctl is-failed stash-maintenance` returns 0. Visible.
- **API key file unreadable** → script's `[ ! -r "${cfg.apiKeyFile}" ]` check exits 1.
- **GraphQL endpoint unreachable** → `curl --fail --max-time 30` returns non-zero; `errexit` aborts.
- **GraphQL response contains `errors`** → `jq -e '.errors'` triggers in the `post` helper; script exits with the error body on stderr.
- **One mutation fails after earlier ones queued** → script aborts. The successfully-queued earlier jobs still execute on Stash. Next day's run will retry the failed mutation.

No retry/backoff in the script. Daily timer is the retry mechanism. Failures live in `journalctl -u stash-maintenance` and surface via `systemctl is-failed`.

## Verification

```bash
# Build gate (evaluates + builds the affected derivation)
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel

# After deploy, on scheelite:
systemctl list-timers stash-maintenance   # Shows next fire time
sudo systemctl start stash-maintenance    # Manual smoke test
journalctl -u stash-maintenance -f        # Watch 5 job IDs get queued
```

Then in Stash UI → Settings → Tasks (Advanced Mode): confirm 5 queued jobs appear and execute sequentially. Once complete, spot-check a recently-imported scene: Title / Performers / Studio / Date populated indicates Identify ran successfully.

## Files touched

- Modify: `nixos-modules/services/stash/module.nix` (new options + script + assertion + timer + service)
- Modify: `nixos-configurations/scheelite/default.nix` (one enable line)

## Commit shape

1. `nixosModules.theonecfg.services.stash: add scheduled maintenance task`
2. `nixosConfigurations.scheelite: enable Stash scheduled maintenance`

## Decisions deferred

- **Per-task scheduling** (different cadences for `Generate` — heavy — vs the lighter tasks). YAGNI; one cadence covers the common case. If the first-run Generate is too heavy, split into two timers (heavy task weekly, others daily) later.
- **Failure notifications** (SMTP / ntfy / push). Blocked on `theonecfg.services.smtp-relay` being introduced separately (deferred in memory `project_smtp_relay`). For now, manual journal inspection.
- **Auto-trigger on Whisparr import**: alternative to scheduled runs — fire maintenance whenever Whisparr imports a file. Possible via Whisparr's custom-script hook. Tighter coupling; the daily schedule is simpler and adequate.
- **Per-stashbox source override**: currently uses all configured `stashBoxes` as Identify sources. If a user ever wants Identify to use only a subset, add an option to scope. YAGNI for now.
- **Polling for job completion**: the script fires-and-forgets. Could be extended to poll Stash's `findJobs` query and wait until the queue drains, exposing real per-task timing. More complex; not needed.

---

# Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `theonecfg.services.stash.scheduledMaintenance` (timer + oneshot + GraphQL script) and enable it on scheelite.

**Architecture:** see the Design section above. One module extension + one host-config line.

**Tech Stack:** NixOS module system, `pkgs.writeShellApplication`, systemd timer + oneshot service, Stash GraphQL.

## Pre-flight

- Branch: `rework-scheelite`. Each task ends in an atomic commit on this branch.
- **No `Co-Authored-By:`** trailers (memory `feedback_no_coauthors`).
- **No future-refs** in commit messages — describe what's true at that point in history (memory `feedback_commit_msg_no_future_refs`).
- **Commit subjects use nix attribute paths** for nix-reachable changes (`nixosModules.theonecfg.services.stash`, `nixosConfigurations.scheelite`); file paths only for non-nix files (memory `feedback_commit_message_paths`).
- Build gate: `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel`. Do **not** run `nix flake check` — slow and unnecessary (memory `feedback_no_flake_check`).
- User runs every `nixos-rebuild --target-host scheelite` deploy themselves; pre-deploy build verification is done on the workstation.

## Phase 1 — Extend `theonecfg.services.stash` with scheduled maintenance

### Task 1.1 — Module additions

**Files:**

- Modify: `nixos-modules/services/stash/module.nix`

**Steps:**

- [ ] **Step 1: Add option declarations**

Inside `options.theonecfg.services.stash = { ... }`, after the existing `apiKeyFile` option, append:

```nix
scheduledMaintenance = {
  enable = mkEnableOption "Daily Stash library maintenance (scan + identify + auto tag + generate + clean)";
  schedule = mkOption {
    type = str;
    default = "*-*-* 03:00:00";
    description = ''
      systemd OnCalendar expression for when the maintenance pipeline fires.
      Default is 03:00 local time, daily.
    '';
  };
};
```

- [ ] **Step 2: Add request bodies and maintenance script to the `let` block**

In the `let` block (after the existing `stashApikeySplice` and the submodule type declarations), add:

```nix
identifyBody = builtins.toJSON {
  query = "mutation Identify($sources: [ScraperSourceInput!]!) { metadataIdentify(input: { sources: $sources }) }";
  variables.sources = map (b: {
    source = { stash_box_endpoint = b.endpoint; };
  }) cfg.stashBoxes;
};

simpleBody = mutation: builtins.toJSON {
  query = "mutation { ${mutation} }";
};

scanBody     = simpleBody "metadataScan(input: {})";
autoTagBody  = simpleBody "metadataAutoTag(input: {})";
generateBody = simpleBody "metadataGenerate(input: {})";
cleanBody    = simpleBody "metadataClean(input: {})";

stashMaintenance = pkgs.writeShellApplication {
  name = "stash-maintenance";
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
  text = ''
    if [ ! -r "${toString cfg.apiKeyFile}" ]; then
      echo "stash API key not readable: ${toString cfg.apiKeyFile}" >&2
      exit 1
    fi
    apikey="$(tr -d '\r\n' < "${toString cfg.apiKeyFile}")"
    endpoint="http://127.0.0.1:${toString cfg.port}/graphql"

    post() {
      local label="$1" body="$2" response
      echo "Triggering: $label"
      response="$(curl -fsS --max-time 30 -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -H "ApiKey: $apikey" \
        -d "$body")"
      if jq -e '.errors' <<< "$response" >/dev/null 2>&1; then
        echo "  GraphQL error: $response" >&2
        return 1
      fi
      echo "  Job ID: $(jq -r '.data | to_entries[0].value' <<< "$response")"
    }

    post "scan"     '${scanBody}'
    post "identify" '${identifyBody}'
    post "autotag"  '${autoTagBody}'
    post "generate" '${generateBody}'
    post "clean"    '${cleanBody}'

    echo "All maintenance tasks queued. Stash executes them serially via its internal task queue."
  '';
};
```

Notes:
- `toString cfg.apiKeyFile` forces the path-or-null option through `toString`. If `apiKeyFile` is `null`, eval would otherwise produce `null` interpolated as the empty string, which makes the runtime check confusing. The assertion in Step 3 ensures we never hit this path, but `toString` makes the eval-time interpolation safe regardless.
- `writeShellApplication` already sets `errexit/nounset/pipefail`; no `set` line needed.

- [ ] **Step 3: Add assertion + systemd units in the `mkMerge` branch**

Inside the always-on `mkMerge` branch (the same block that defines `services.stash`, `users.users.stash.extraGroups`, etc.), append after `sops.secrets`:

```nix
assertions = [
  {
    assertion = !cfg.scheduledMaintenance.enable || cfg.apiKeyFile != null;
    message = "theonecfg.services.stash.scheduledMaintenance.enable requires apiKeyFile to be set (Stash's GraphQL mutations refuse requests without an ApiKey header).";
  }
];

systemd.timers.stash-maintenance = mkIf cfg.scheduledMaintenance.enable {
  description = "Daily Stash library maintenance";
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = cfg.scheduledMaintenance.schedule;
    Persistent = true;
  };
};

systemd.services.stash-maintenance = mkIf cfg.scheduledMaintenance.enable {
  description = "Stash library maintenance: scan + identify + auto tag + generate + clean";
  after = [ "stash.service" ];
  requires = [ "stash.service" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${stashMaintenance}/bin/stash-maintenance";
  };
};
```

- [ ] **Step 4: Verify with nix build**

```bash
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: succeeds. No flake-wide check needed; this evaluates the affected module and builds the host closure, which is the right scope. The new option defaults to `enable = false` so nothing on the host changes behavior yet.

- [ ] **Step 5: Commit**

```bash
git add nixos-modules/services/stash/module.nix
git commit -m "nixosModules.theonecfg.services.stash: add scheduled maintenance task"
```

## Phase 2 — Enable on scheelite

### Task 2.1 — Host enablement

**Files:**

- Modify: `nixos-configurations/scheelite/default.nix`

**Steps:**

- [ ] **Step 1: Add the enable line**

Locate the existing `theonecfg.services.stash = { ... }` block (around line 197). Inside that block, after `stashBoxes`, add:

```nix
scheduledMaintenance.enable = true;
```

(Schedule defaults to `*-*-* 03:00:00`. Override only if a different time is wanted; not needed for v1.)

- [ ] **Step 2: Verify with nix build**

```bash
nix build .#nixosConfigurations.scheelite.config.system.build.toplevel
```

Expected: succeeds. Build closure now contains the maintenance timer + service units and the `stashMaintenance` script derivation.

- [ ] **Step 3: Commit**

```bash
git add nixos-configurations/scheelite/default.nix
git commit -m "nixosConfigurations.scheelite: enable Stash scheduled maintenance"
```

## Phase 3 — Deploy and verify

Operational. No commits.

### Task 3.1 — Deploy

- [ ] **Step 1: Run nixos-rebuild from the workstation**

```fish
nixos-rebuild --flake .#scheelite --target-host scheelite --sudo --ask-sudo-password switch
```

Expected: switch succeeds. New units `stash-maintenance.service` and `stash-maintenance.timer` enter the system.

### Task 3.2 — Verify the timer is registered

- [ ] **Step 1: On scheelite, check the timer**

```fish
systemctl list-timers stash-maintenance
```

Expected: a row with `LEFT` showing time-until-next-fire (under ~24h), `NEXT` showing the next 03:00 timestamp, `UNIT = stash-maintenance.timer`, `ACTIVATES = stash-maintenance.service`.

If the timer doesn't appear, the unit isn't `enabled`. Check `systemctl status stash-maintenance.timer` for hints.

### Task 3.3 — Manual smoke test

- [ ] **Step 1: Trigger the service manually**

```fish
sudo systemctl start stash-maintenance
journalctl -u stash-maintenance --since '1 minute ago' --no-pager
```

Expected journal output (one block per mutation):

```
Triggering: scan
  Job ID: <integer>
Triggering: identify
  Job ID: <integer>
Triggering: autotag
  Job ID: <integer>
Triggering: generate
  Job ID: <integer>
Triggering: clean
  Job ID: <integer>
All maintenance tasks queued. Stash executes them serially via its internal task queue.
```

If any mutation returns a GraphQL error: the corresponding line will show `GraphQL error: <response body>`. Most likely causes are:
- API key wrong / missing — re-check `cfg.apiKeyFile` and that Stash's `config.yml` contains the same key.
- Stash version's GraphQL schema differs — the mutation arg names may have changed; update the request bodies in the script.

### Task 3.4 — Confirm in Stash UI

- [ ] **Step 1: Open Stash → Settings → Tasks (Advanced Mode enabled)**

URL: `https://stash.scheelite.dev/settings?tab=tasks`.

Expected: a "Job Queue" panel shows the 5 just-queued tasks. They execute serially. First-run Generate may take a long time (CPU-intensive thumbnail generation across the full library).

### Task 3.5 — End-to-end verification at next scheduled fire

- [ ] **Step 1: Wait for the next scheduled run** (or skip if Task 3.3's manual run is sufficient)

The next day after 03:00 local time, run:

```fish
systemctl status stash-maintenance --no-pager
journalctl -u stash-maintenance --since 'yesterday' --no-pager | tail -20
```

Expected: `Last triggered: ...` shows today's 03:00 firing. Journal shows the same "Triggering: ..." blocks as the manual run.

## End-to-end verification

1. `nix build .#nixosConfigurations.scheelite.config.system.build.toplevel` succeeds.
2. Deploy succeeds; `systemctl list-timers stash-maintenance` shows next 03:00 fire time.
3. `sudo systemctl start stash-maintenance` queues 5 jobs in Stash with no GraphQL errors.
4. Stash UI → Settings → Tasks shows the queued jobs running sequentially.
5. After a real overnight fire, a spot-checked recently-imported scene has Title / Performers / Studio / Date populated in Stash, indicating Identify ran successfully.

## Execution

Plan complete and saved to `docs/plans/active/stash-scheduled-maintenance.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
