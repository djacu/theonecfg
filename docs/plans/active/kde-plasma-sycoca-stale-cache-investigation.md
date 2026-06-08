# KDE Plasma sycoca cache — open investigation

Date: 2026-05-10. Host: `argentite`. Plasma 6.6.4 on NixOS, standalone home-manager.

## What surfaced

Added `pkgs.fluffychat` to `home-modules/packages/messaging/module.nix`,
rebuilt nixos + home-manager. FluffyChat did not appear in either:

- KRunner (Alt+Space)
- Kickoff (panel start-menu app search) — only the "Run fluffychat"
  Command-Line fallback row, which is plasmashell's PATH-lookup, not
  an indexed application.

A series of cache rebuilds eventually got FluffyChat to appear, but
*why* the earlier rebuilds didn't suffice and the later one did is not
fully understood. Captured here so the next occurrence can be
diagnosed without re-deriving everything.

## Verified facts

### Install was correct

- `which fluffychat` → `/home/djacu/.nix-profile/bin/fluffychat`
- `~/.nix-profile/share/applications/Fluffychat.desktop` exists as a
  symlink into `fluffychat-linux-2.4.1`'s store output.
- The `.desktop` file is well-formed: `Type=Application`, valid
  `Exec=fluffychat`, valid `Categories=` (`Chat;Network;InstantMessaging`),
  no `NoDisplay`, no `OnlyShowIn`/`NotShowIn`, no `Hidden`.
- `/home/djacu/.nix-profile/share` is in `$XDG_DATA_DIRS` in the
  user's interactive fish shell.

### sycoca initially missed it

After `kbuildsycoca6 --noincremental`, checking the cache:

```fish
strings ~/.cache/ksycoca6_* | grep -ci fluffy
# → 0
```

Three cache files existed, all identical 612271-byte size, different
env-hash suffixes:

```
~/.cache/ksycoca6_en_ozKJCLhF37xXjpOLZqU4iGUaj2Q=
~/.cache/ksycoca6_en_QYRMSHtWBS34OSLZM4giRyzEShE=
~/.cache/ksycoca6_en_WULNNHzFzla64vtGYPuQB_FjBGs=
```

The sycoca filename suffix is a hash of `$XDG_DATA_DIRS`. Multiple
files = multiple distinct envs writing the same cache. The presence of
three files after a single `rm + kbuildsycoca6` means at least two
*other* processes also ran `kbuildsycoca6` in the same window.

### kbuildsycoca6 *can* index it

Re-running with Qt logging enabled:

```fish
env QT_LOGGING_RULES='kf.service.*=true' kbuildsycoca6 --noincremental
```

logged (excerpted):

```
kf.service.sycoca: Creating KService from
  "/nix/store/9ys5p9p62g0qjjx8mn5fgb42hq2s1g4x-home-manager-path/share/applications/Fluffychat.desktop"
```

`ls /nix/store/9ys5p9p…-home-manager-path/share/applications/` confirms
`Fluffychat.desktop` is in that store path. So the desktop file *was*
on a dir kbuildsycoca6 walks — the previous "0" result didn't mean
the path was excluded, it meant something else.

After this verbose run, FluffyChat appeared in both KRunner and
Kickoff with no further intervention.

### Profile-path findings (likely a separate problem)

- `readlink -f ~/.nix-profile` →
  `/nix/store/64lnmimgqs1gpy8394v1h3x6s1yj8qm8-user-environment`
  — i.e., a legacy `nix-env` profile, *not* a home-manager-path.
- `readlink -f ~/.local/state/nix/profile` →
  `/home/djacu/.local/state/nix/profile` (not a symlink at all — a
  regular directory).
- The active home-manager content sits at
  `/nix/store/9ys5p9p…-home-manager-path/`, which is what
  kbuildsycoca6 actually scans, but neither of the above readlinks
  points there.

This means there's a legacy `nix-env` profile coexisting with
home-manager. May or may not be related to the sycoca refresh
behaviour — see open questions.

### Flag note

`kbuildsycoca6 --verbose` does **not** exist on Plasma 6 — passing it
causes the command to exit with `Unknown option 'verbose'.` without
rebuilding. Use `QT_LOGGING_RULES='kf.service.*=true' kbuildsycoca6`
for verbose output instead. The first ~30 minutes of debugging were
silently wasted on a failed `--verbose` flag.

## Open questions

1. **Why did plain `kbuildsycoca6 --noincremental` leave the cache
   without fluffychat, when the same flag set indexed it correctly
   moments later under `QT_LOGGING_RULES`?** These should be
   semantically identical operations. Hypotheses, none verified:

   - Race with `kded` (or plasmashell) rebuilding sycoca concurrently
     using a different env, overwriting the user's good cache.
   - The `strings | grep` check ran before kbuildsycoca6's write
     completed.
   - Qt logging changes a path that affects rebuild result (unlikely
     but not ruled out).

1. **Who else runs kbuildsycoca6?** Three cache files appeared after
   one user-initiated run, meaning two other processes also rebuilt.
   Most likely `kded6` (KDE Daemon) and possibly plasmashell itself.
   Not directly observed.

1. **What `XDG_DATA_DIRS` does the *running* plasma session use?** We
   never read it. Attempts to inspect via
   `cat /proc/(pgrep -x plasmashell)/environ` hung in fish. Root cause
   unknown — possibly `pgrep` returning multiple PIDs, possibly an
   unrelated fish redirect quirk.

1. **Does the legacy `nix-env` profile shadowing `~/.nix-profile`
   cause this?** A plausible theory: KDE's directory-watching for
   sycoca auto-rebuild keys off a path that resolves to the legacy
   user-environment, not the home-manager-path that actually changes
   on rebuild — so KDE never knows to refresh. Plausible, unverified.

## Diagnostic recipe for next time

Replace `<app>` with the app name (case-insensitively).

```fish
# 1. Install + .desktop sanity
which <app>
ls -la ~/.nix-profile/share/applications/ | grep -i <app>
cat ~/.nix-profile/share/applications/<App>.desktop

# 2. XDG_DATA_DIRS, shell vs plasmashell
echo $XDG_DATA_DIRS | tr ':' '\n'
cat /proc/(pgrep -x plasmashell | head -1)/environ \
  | tr '\0' '\n' | grep '^XDG_DATA_DIRS='

# 3. Rebuild + check whether it's in sycoca
kbuildsycoca6 --noincremental
strings ~/.cache/ksycoca6_* 2>/dev/null | grep -ci <app>

# 4. Verbose rebuild: what dirs are walked, what services get created
env QT_LOGGING_RULES='kf.service.*=true' kbuildsycoca6 --noincremental 2>&1 \
  | grep -E 'Looking up applications|Creating KService.*<app>'

# 5. Profile-path resolution
readlink -f ~/.nix-profile
readlink -f ~/.local/state/nix/profile
ls -la ~/.cache/ksycoca6_*  # mtimes reveal who-rebuilt-when

# 6. Fallback: force plasmashell to start clean with current env
pkill -x plasmashell
# (respawns automatically; setsid plasmashell >/dev/null 2>&1 & if not)
```

## Related cleanup (separate task)

Untangle the legacy `nix-env` profile vs home-manager profile:

- `nix-env -q` to see what's in the legacy profile.
- Remove anything home-manager already manages.
- Confirm `~/.nix-profile` ends up pointing at the home-manager-path
  after cleanup.
- Retest: does kbuildsycoca6 still need a manual run after a rebuild,
  or does KDE auto-refresh now?
