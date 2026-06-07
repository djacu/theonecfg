# scheelite — investigate `statx … Protocol driver not attached` warnings

Status: active (investigation only)
Owner: dan
Last updated: 2026-06-01

## Why this plan exists

`systemd-tmpfiles-clean.service` (and occasionally
`systemd-tmpfiles-setup.service`) logs lines of the form:

```
statx(<path>) failed: Protocol driver not attached
```

The error string corresponds to `errno 49 = EUNATCH`, verified via
`perl -MErrno`. NOT `ENODEV` (errno 19, "No such device") — the
earlier session-summary characterization was wrong.

The warnings don't block tmpfiles processing — failed entries are
skipped — so user-visible impact is "noisy journal" plus a yellow
`degraded` state on some boots.

The previous in-conversation hypothesis ("PrivateTmp namespace
isolation makes the mount invisible from the host, hence ENODEV")
is doubly wrong: ENODEV isn't the actual errno, and PrivateTmp
mount targets ARE visible from the host's mount namespace anyway
(the per-service namespace contains a *bind* of the host directory,
not a hidden mount).

This plan exists to actually figure out what EUNATCH from statx
means in this context and whether action is warranted.

## Verified upstream tmpfiles.d declarations

The three Family-B paths the session called "unexplained" are all
declared by upstream packages with tmpfiles entries that include
non-zero ages (i.e., the daily clean pass walks them):

- `/nix/var/nix/builds` — declared in
  `<nixpkgs>/nixos/modules/services/system/nix-daemon.nix:141`:
  ```
  d /nix/var/nix/builds 0755 ${nix.daemonUser} ${nix.daemonGroup} 7d -
  ```
- `/var/lib/systemd/coredump` — `<systemd>/example/tmpfiles.d/systemd.conf`:
  ```
  d /var/lib/systemd/coredump 0755 root root 2w
  ```
- `/var/lib/systemd/ephemeral-trees` — same file, with comment:
  > Files and directories in /var/lib/systemd/ephemeral-trees are
  > locked by pid 1 to prevent tmpfiles from removing them, and
  > tmpfiles is told to clean up anything in
  > /var/lib/systemd/ephemeral-trees that isn't locked
  > unconditionally.

The `ephemeral-trees` comment is suggestive: tmpfiles is *designed*
to attempt operations on paths PID 1 has actively protected. EUNATCH
from `statx` on such a path is plausibly the kernel signaling
"detached mount" or "in-flight propagation event."

## Confounder: impermanence on scheelite

`nixos-configurations/scheelite/impermanence.nix:33` adds
`/var/lib/systemd/coredump` to the persistence list. That means at
runtime, scheelite has a bind from `/persist/var/lib/systemd/coredump`
to `/var/lib/systemd/coredump`. Stacked mounts + namespace
propagation are the typical EUNATCH-class scenario.

This is also a baseline question: do `argentite`, `cassiterite`,
`malachite` (no impermanence on these paths) see the same warnings?
If only scheelite — impermanence-stacking is implicated. If
everywhere — it's stock NixOS / systemd.

## Investigation steps

Run on scheelite, fish syntax:

```fish
# 1. Enumerate every affected path over the last 30 days
sudo journalctl -u systemd-tmpfiles-clean.service \
                -u systemd-tmpfiles-setup.service \
                --since '30 days ago' --no-pager \
  | grep -E 'statx.*Protocol driver' \
  | sed -E 's/.*statx\(([^)]+)\).*/\1/' \
  | sort -u > /tmp/eunatch-paths.txt
cat /tmp/eunatch-paths.txt

# 2. Frequency profile — is this 1 line/boot or 100/day?
sudo journalctl -u systemd-tmpfiles-clean.service \
                --since '30 days ago' --no-pager \
  | grep -cE 'Protocol driver not attached'

# 3. Cross-host baseline (if any laptop is reachable):
#    do the same journalctl/grep there
ssh malachite 'sudo journalctl -u systemd-tmpfiles-clean.service \
               --since "30 days ago" --no-pager \
               | grep -cE "Protocol driver not attached"'

# 4. Live reproduction — does the warning fire on demand?
sudo systemd-tmpfiles --clean --dry-run 2>&1 \
  | grep -E 'Protocol driver not attached'

# 5. For each affected path: what's its current mount/bind state?
for p in (cat /tmp/eunatch-paths.txt)
    echo "=== $p ==="
    sudo findmnt --target "$p" 2>&1
    sudo stat "$p" 2>&1
    sudo ls -ld "$p" 2>&1
end
```

## Questions the data should answer

- Is the path set the same across hosts, or scheelite-only?
- Is the warning periodic (daily-timer correlated) or event-driven
  (correlates with a service start/stop)?
- For each path: is it bind-mounted from `/persist`? Is there an
  active service holding it via mount-namespace propagation?
- Does `--dry-run` reliably reproduce, or is the warning timing-
  dependent on transient state?

## Possible outcomes

1. **Scheelite-only**: impermanence bind-stacking interacts with the
   tmpfiles walk; the EUNATCH is a side-effect of the stacked
   mount's propagation state. Likely cosmetic, no fix.
1. **All hosts**: it's stock NixOS + systemd behavior. File upstream
   issue (or find existing one), document as known cosmetic.
1. **Specific path actionable**: e.g., `/nix/var/nix/builds`'s 7d
   age is removing in-flight sandbox build dirs and the EUNATCH is
   the kernel rejecting the operation on a locked dentry. Reduce
   tmpfiles' walk by overriding the upstream entry with `0` age (no
   clean) for that path.
1. **Volume justifies suppression**: drop the warning class at the
   shipper. Repo uses alloy
   (`nixos-configurations/scheelite/default.nix:370`); the right
   place is a `stage.drop` in
   `nixos-modules/services/monitoring/alloy/module.nix`'s
   `loki.process` pipeline matching the line pattern. journald
   itself has no message-level regex filter.

## Exit criteria

- All paths in `/tmp/eunatch-paths.txt` classified into one of the
  outcomes above.
- Cross-host comparison done.
- Outcome chosen and documented.
- This plan moves to `completed/` with the outcome summary.

## What this plan does *not* do

- Does not propose code changes pre-investigation.
- Does not touch tmpfiles configuration speculatively. (The recent
  "obvious-looking" prowlarr tmpfiles fix turned up an unrelated
  upstream data-path bug; be wary of pattern-matching without
  verification.)
- Does not assume the answer is "suppress." Cosmetic warnings on
  stock NixOS often have legitimate diagnostic value if you read
  the journal during an actual issue.
