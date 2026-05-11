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
