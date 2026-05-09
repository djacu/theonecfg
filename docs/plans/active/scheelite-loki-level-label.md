# scheelite — Loki `level` label

Status: completed 2026-05-09
Owner: dan
Last updated: 2026-05-09

## Outcome

All five phases shipped on 2026-05-09. The dashboard now filters by a real
Loki label (`level`) extracted at Alloy ingestion. Loki is back at default
`info` log level (full operational visibility); known-noise warn-level
patterns are dropped at the Alloy shipper before they reach Loki.

Two deviations from the original plan, both explained inline below:

- **Phase 3** also updated `docs/reference/grafana-dashboards/README.md`
  (originally deferred to Phase 5). The README's existing description
  was about to be inaccurate after the JSON change, so fixing both
  in one commit was natural.
- **Phase 5** added an Alloy `stage.match` block that drops two known
  Loki self-noise patterns (`failed mapping AST`, `could not determine
  query overlaps`). This wasn't in the original plan — it surfaced
  during Phase 4 UI verification when the user noticed Loki was still
  emitting warn-level lines on every dashboard interaction. With those
  dropped at ingestion, reverting Phase 1's `log_level = "warn"` no
  longer re-pollutes the dashboard.

Commits, in order:

| Phase | Commit | Description |
|---|---|---|
| (plan) | `3653857` | docs/plans/active: add scheelite-loki-level-label plan |
| 1 | `097a4fa` | nixos-modules/services/monitoring/loki: set log_level=warn |
| 2 | `57d5881` | nixos-modules/services/monitoring/alloy: extract level label from journal lines |
| 3 | `83ad2a8` | docs/reference/grafana-dashboards/homelab-logs: filter by level label |
| 5 | `c7ff1be` | nixos-modules/services/monitoring/alloy: drop loki self-noise at ingestion |
| 5 | `4f34c7e` | nixos-modules/services/monitoring/loki: restore default log_level |

## Goal

Make Grafana's Logs dashboard correctly filter by log level. Replace the current
substring regex (`|~ "(?i)$level"`) — which leaks any line that happens to
contain the word "error" anywhere — with a real Loki label set at ingestion
time.

## Why this is needed

The dashboard's `level` template variable backs a content-substring filter, not
a level filter. So any info-level line that *contains* the word "error" or
"warn" inside its message body slips through. Loki itself is the worst
offender: every info-level query log it emits contains the literal text of
the dashboard's own `(?i)error|warn` filter, creating a self-feeding loop.

Empirical measurement (1-hour window on scheelite, 2026-05-08):

| Service | Journal lines |
|---|---|
| loki.service | 14,183 |
| oauth2-proxy.service | 3,383 |
| grafana.service | 1,017 |

The fix has two parts:
1. Short-term insurance — silence Loki's own info chatter at the producer.
2. Structural — extract a real `level` label in Alloy and switch the
   dashboard to label-based filtering.

## Decisions

These were resolved with the user before drafting:

- **Option 1 (Loki `log_level=warn`) AND Option 3 (level label).** Option 1
  ships first as a one-line insurance during the transition; revertable later
  if desired (one line, no data migration).
- **Old data: hard cut.** Server is a few weeks old; user does not care about
  retroactive level filtering for pre-rollout logs.
- **5 buckets + unlabeled.** Levels normalized to `critical`, `error`,
  `warning`, `info`, `debug`. Lines whose level couldn't be parsed get an
  explicit `unlabeled` value (selectable in the dashboard) so nothing is
  silently hidden.
- **Default dashboard selection: `[critical, error, warning]`** — fatal-class
  events visible without explicit action.

## Background — service log format catalog

Sampled on scheelite 2026-05-08 across enabled services. Three families:

| Family | Format | Services in this stack |
|---|---|---|
| A | `level=<word>` (Go logfmt) | alloy, grafana, loki, prometheus, scrutiny |
| B | `[<word>]` (Serilog/AdGuard/celery) | adguardhome, jellyfin, paperless-celery, prowlarr, radarr, sonarr, sonarr-anime, whisparr, seerr |
| C | none / unique | oauth2-proxy (HTTP access logs), redis-paperless, qbittorrent, recyclarr, kanidm |

A single regex covers families A and B (~70% of journal volume by line count).
Family C either has no level concept or uses unique formats; those entries
end up `unlabeled`. Future services can be added by extending the regex.

## Mapping table

Source-text words map to canonical buckets via case-insensitive match:

```
fatal | crit | critical          → critical
err   | error                    → error
wrn   | warn | warning           → warning
inf   | info | notice            → info
dbg   | debug | trace            → debug
(no match)                       → unlabeled
```

Cardinality cost: 6 string values for one new label. Combined with `unit`
(~50) and `host` (1), total label cardinality stays well within Loki's
default streams-per-tenant limits.

---

## Phase 1 — Loki `log_level=warn` (insurance) — done in `097a4fa`, reverted in Phase 5 (`4f34c7e`)

**Why first**: silences Loki's own info chatter immediately so the dashboard
isn't drowning in self-feedback noise during phases 2–4. Trivially revertable
once option 3 lands.

**Files**:
- `nixos-modules/services/monitoring/loki/module.nix`

**Change**: add inside `services.loki.configuration` block:

```nix
server = {
  http_listen_address = "127.0.0.1";
  http_listen_port = cfg.port;
  log_level = "warn";   # NEW
};
```

**Deploy**: user runs `nixos-rebuild switch --target-host scheelite ...`.

**Verify**:
- `ssh scheelite 'systemctl show loki.service -p MainPID --value'` — note PID.
- `ssh scheelite 'journalctl -u loki.service --since "5 min ago" --no-pager | wc -l'`
  — should drop sharply (was ~14k/hour pre-change).
- Open Grafana Logs dashboard with default filters; confirm Loki is no
  longer the top emitter.

**Risk**: lose Loki's per-query latency / cache stat info. Acceptable — user
isn't tuning Loki. Revert is a single-line removal.

**Commit message** (suggested): `nixos-modules/services/monitoring/loki: set log_level=warn`

---

## Phase 2 — Add `level` extraction in Alloy — done in `57d5881`

**Files**:
- `nixos-modules/services/monitoring/alloy/module.nix`

**Change**: insert a `loki.process "level"` block between the journal source
and the writer. The journal source's `forward_to` redirects to the process
stage; the process stage forwards to `loki.write.default`.

Sketch (final exact regex/template determined during implementation; commit
verified on host):

```alloy
loki.source.journal "journal" {
  forward_to    = [loki.process.level.receiver]   # was loki.write.default.receiver
  relabel_rules = loki.relabel.journal.rules
  labels        = { job = "systemd-journal", host = "scheelite" }
}

loki.process "level" {
  forward_to = [loki.write.default.receiver]

  // Default: anything that doesn't match below ends up "unlabeled".
  stage.template {
    source   = "level"
    template = "unlabeled"
  }

  // Family A: `level=<word>` (Go logfmt). Family B: `[<word>]` (Serilog/celery/AdGuard).
  // Case-insensitive; lowercase via Go template in the next stage.
  stage.regex {
    expression = "(?:level=|\\[)(?P<level>(?i:fatal|crit|critical|err|error|wrn|warn|warning|inf|info|notice|dbg|debug|trace))(?:\\b|\\])"
  }

  // Lowercase, then normalize to the 5 canonical buckets + unlabeled.
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.template {
    source   = "level"
    template = "{{ if or (eq .Value \"fatal\") (eq .Value \"crit\") (eq .Value \"critical\") }}critical{{ else if or (eq .Value \"err\") (eq .Value \"error\") }}error{{ else if or (eq .Value \"wrn\") (eq .Value \"warn\") (eq .Value \"warning\") }}warning{{ else if or (eq .Value \"inf\") (eq .Value \"info\") (eq .Value \"notice\") }}info{{ else if or (eq .Value \"dbg\") (eq .Value \"debug\") (eq .Value \"trace\") }}debug{{ else }}{{ .Value }}{{ end }}"
  }

  stage.labels {
    values = { level = "" }   // promote `level` from extracted map to label
  }
}
```

**Notes on the design**:

- The first `stage.template` seeds `level = "unlabeled"` *before* the regex,
  so non-matching lines still carry the bucket label rather than no label.
  The regex overwrites `level` on a successful match.
- The lowercase pass is its own stage so the if-chain only has to compare
  lowercase variants. Cleaner than putting `ToLower` inside every `eq`.
- Final `stage.labels` with `level = ""` promotes the extracted value (the
  empty-string convention means "use the same name").
- Cardinality: 6 fixed string values. No risk of label explosion from
  malformed log lines because the regex captures only an enumerated set.

**Deploy**: user runs `nixos-rebuild switch --target-host scheelite ...`.

**Verify**:
- `ssh scheelite 'curl -sG http://127.0.0.1:3100/loki/api/v1/labels'` — should
  list `level` alongside the existing labels.
- `ssh scheelite 'curl -sG --data-urlencode label=level http://127.0.0.1:3100/loki/api/v1/label/level/values'`
  — values should be exactly `critical|error|warning|info|debug|unlabeled`.
- `ssh scheelite 'curl -sG --data-urlencode "query={job=\"systemd-journal\", unit=\"loki.service\", level=\"warning\"}" --data-urlencode "limit=5" http://127.0.0.1:3100/loki/api/v1/query'`
  — should return Loki's own warn-level lines (post phase 1).
- Spot-check a family-A and family-B service:
  - alloy: `{unit="alloy.service", level="info"}` should return entries.
  - sonarr: `{unit="sonarr.service", level="info"}` should return entries.
- Spot-check family-C: `{unit="oauth2-proxy.service", level="unlabeled"}`
  should return entries (HTTP access logs have no level).

**Risk**:
- **Regex over-matches**: e.g. a log line containing `[Error counter]` or
  `level=trace_started` could capture an unintended substring. Mitigation:
  the regex requires the word to be terminated by a word boundary or
  closing bracket, and the captured group is closed-set enumerated.
- **Performance**: regex stage runs on every line. RE2 is fast but at
  full ingest rate (~25k lines/hr post phase 1) the cost is negligible.
  Verify by checking Alloy's CPU usage doesn't increase meaningfully
  (`systemctl status alloy.service` post-deploy).
- **Stage ordering**: if the lowercase template runs before the regex, no
  effect. If it runs after, it transforms whatever the regex extracted. The
  ordering above (default → regex → lowercase → if-chain → label) is
  correct — verified by reading Alloy's `loki.process` docs in
  `/tmp/investigate/alloy/docs/sources/reference/components/loki/loki.process.md`.

**Commit message** (suggested): `nixos-modules/services/monitoring/alloy: extract level label from journal lines`

---

## Phase 3 — Update the Logs dashboard — done in `83ad2a8`

**Files** (the README update was originally Phase 5; folded in here because
the existing description would otherwise contradict the new behavior):
- `docs/reference/grafana-dashboards/homelab-logs.json`
- `docs/reference/grafana-dashboards/README.md`

**Changes** (six panels + one template variable):

1. **`level` template variable** (`templating.list[1]`):
   - Replace options array with: `critical`, `error`, `warning`, `info`, `debug`, `unlabeled`
   - Set default selection to `[critical, error, warning]`
   - Update the `query` field to match new comma-separated value list

2. **Panel "Error lines (last 1h, all units)"** — `targets[0].expr`:
   ```
   sum(count_over_time({job="systemd-journal", level=~"error|critical"} [1h]))
   ```

3. **Panel "Error lines (last 24h, all units)"** — `targets[0].expr`:
   ```
   sum(count_over_time({job="systemd-journal", level=~"error|critical"} [24h]))
   ```

4. **Panel "Top 10 units by error count (1h)"** — `targets[0].expr`:
   ```
   topk(10, sum by (unit) (count_over_time({job="systemd-journal", level=~"error|critical"} [1h])))
   ```

5. **Panel "Matching log volume over time (by unit)"** — `targets[0].expr`:
   ```
   sum by (unit) (count_over_time({job="systemd-journal", unit=~"$unit", level=~"$level"} [$__interval]))
   ```

6. **Panel "Logs"** — `targets[0].expr`:
   ```
   {job="systemd-journal", unit=~"$unit", level=~"$level"}
   ```

The "Log lines/sec for selected unit(s)" panel needs no change — it counts
all lines for the selected unit regardless of level.

**Deploy**: dashboards are picked up by Grafana via provisioning on next
service restart, or via UI re-import. No nixos-rebuild needed if Grafana's
provisioning watches the file (verify in `nixos-modules/services/monitoring/grafana/module.nix`).

**Verify**:
- Open the dashboard. Default selection should be `[critical, error, warning]`.
- The "Logs" panel should show only those levels — no info lines should
  appear unless explicitly selected.
- Change the level dropdown to include `unlabeled` only; family-C services
  (oauth2-proxy access logs etc.) should appear.
- Self-feedback test: open dashboard, leave it on auto-refresh for 1 minute,
  refresh; loki.service should NOT dominate the panel (its own info-level
  query logs no longer match `level=~"error|critical|warning"`).
- Top-10 error table: should be dominated by services that genuinely error
  (AdGuard's DoH transients, occasional *arr exceptions), not by Loki.

**Risk**:
- **Old logs invisible after change**: pre-phase-2 lines have no `level`
  label. Per scope decision: hard cut, accepted.
- **JSON regression**: hand-editing Grafana JSON is error-prone. After
  each panel edit, validate via `jq . dashboard.json > /dev/null` and
  visually load in Grafana.

**Commit message** (suggested): `docs/reference/grafana-dashboards/homelab-logs: filter by level label`

---

## Phase 4 — End-to-end verification — done

API-level checks all passed:

- Cardinality stayed at the 6 planned values (`critical`, `error`,
  `warning`, `info`, `debug`, `unlabeled`); only the buckets that
  had matching events were populated at first observation.
- Family A (Go logfmt): grafana, alloy, prometheus, loki — all
  correctly tagged.
- Family B (Serilog/AdGuard/celery): sonarr, sonarr-anime, prowlarr,
  whisparr, radarr, jellyfin (`[ERR]` works; multi-line .NET stack
  trace continuations correctly stay `unlabeled`), adguardhome
  (`[error]` works) — all correctly tagged.
- Family C (no level concept): oauth2-proxy, redis-paperless, kanidm,
  recyclarr — correctly bucketed as `unlabeled`.
- Top-10 errors panel cleanly dominated by services that genuinely
  error (AdGuard DoH transients, jellyfin DB errors), not Loki itself.

UI-level check surfaced an unplanned issue: with the user's default
selection of `[critical, error, warning]`, Loki's own warn-level
lines on query cancellation and on a transient schema-config quirk
were still showing up — caused by routine dashboard interaction, not
by anything actionable. This drove the Phase 5 deviation below.

---

## Phase 5 — Drop Loki self-noise + revert Phase 1 — done in `c7ff1be` and `4f34c7e`

The original plan had Phase 5 as just (a) documentation and (b) optional
revert of Phase 1. The README documentation work was already folded into
Phase 3. The revert turned out to need one more change first.

**Problem found in Phase 4 UI verification**: Loki at `log_level=warn`
emits two patterns of warn-level chatter that survive the dashboard's
level filter and pollute the default view:

- `failed mapping AST` + `context canceled` — fires every time a query
  is cancelled (every dashboard filter change, every auto-refresh that
  arrives mid-query). This is a side-effect of dashboard *use*, not of
  any actionable problem.
- `could not determine query overlaps on tsdb vs non-tsdb schemas` —
  Loki itself logs this as warn, but says in the same line "letting
  downstream code handle it gracefully." Cosmetic.

Both are real warn-level events, so the label-based filter (correctly)
surfaces them. They're not noise we can silence at the dashboard;
attempting to add `unit!="loki.service"` to the panel filter would
also break "drill into Loki via the unit dropdown" because the static
exclusion would override even an explicit user pick.

**Fix**: drop the two patterns at the Alloy shipper before they reach
Loki. A `stage.match` block at the top of the `loki.process "level"`
pipeline targets `unit="loki.service"` with a line filter for the two
phrases and `action = "drop"`. Other Loki warn/error lines (real
ingester problems, slow queries, storage failures) still flow through
normally; the unit dropdown still surfaces all non-noise Loki lines.

With the noise patterns dropped at ingestion, Loki at default `info`
no longer pollutes the dashboard either: info-level lines carry
`level=info` and are excluded by the default selection. So we
reverted Phase 1's `log_level = "warn"`. Loki regains full
operational visibility (per-query latency, cache stats, ingester
bytes) without re-polluting the dashboard.

**Files**:
- `nixos-modules/services/monitoring/alloy/module.nix` — added
  `stage.match` drop block (`c7ff1be`).
- `nixos-modules/services/monitoring/loki/module.nix` — removed
  `log_level = "warn"` (`4f34c7e`).

**Verified**:
- Loki at info producing ~1300 info-level lines per 3 minutes,
  all correctly tagged `level=info`.
- Loki noise patterns absent from Loki's TSDB after deploy.
- `loki_process_dropped_lines_total{reason="loki_self_noise"}`
  counter incrementing on the Alloy `/metrics` endpoint.

---

## Future-proofing

When adding a new service to scheelite:
1. After deploy, query `{unit="<new-service>.service"}` in Grafana.
2. If lines show `level=unlabeled` despite the service emitting recognizable
   level words, extend the regex in `alloy/module.nix` to cover the new
   format. Add to the catalog table in this doc.
3. Cardinality budget: each new bucket value adds one row to the `level`
   label index. Stay under ~10 distinct values to keep query plans cheap.
