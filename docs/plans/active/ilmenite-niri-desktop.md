# Plan: ilmenite: replace Plasma with niri and Noctalia

**Status:** Design approved 2026-11-23, revised the same day after four
adversarial reviews (see "Review changes"); plan in
`ilmenite-niri-desktop-implementation.md`
**Started:** 2026-11-22
**Owner:** djacu
**Branch:** `djacu/niri-desktop`

## Summary

Replace Plasma on `ilmenite` with niri (scrollable-tiling Wayland compositor),
the Noctalia shell and the Noctalia greeter, to try a lighter desktop that
reaches a usable screen faster and stays snappy. Plasma and SDDM are turned
off on ilmenite from the start; the way back is the previous NixOS generation
in the boot menu. Other hosts keep Plasma and do not change.

The trial only counts if the laptop basics work under niri: password login, lock
with fingerprint, lid and idle sleep, brightness and volume keys, docking at
two desks and in meeting rooms, and the battery behaviour that Plasma's power
daemon provides today. That last part is a hard requirement: the
suspend-then-hibernate setup and power profiles are why this laptop lasts one
to two working days per charge.

The work has two halves. The first is plumbing, written in Nix and verified on
the hardware. The second is tuning (keys, column widths, monitors, look), done
live with the owner in the running session and then frozen into Nix.

## Goals

- ilmenite boots to the Noctalia greeter and into a niri session, with
  Noctalia providing bar, launcher, notifications, lock screen, quick
  settings, polkit prompts and on-screen displays.
- Faster login-to-usable than Plasma, as two numbers. Measure from the
  journal, not a stopwatch: the time from logind's "New session" line for
  the user to the user manager reaching `graphical-session.target`. That
  leaves out the wait for `pam_fprintd` at SDDM (up to 30 s on a typed
  password) and human reaction time. Take Plasma's number from the
  current system before the switch. The owner's own impression is recorded
  next to the numbers.
- Power behaviour under niri matches the table in "Power policy".
- Each known desk arrangement applies by itself when plugged in.
- niri and Noctalia configuration lives in this repo.

## Non-goals

- Any host other than ilmenite. malachite, cassiterite, argentite and
  uraninite keep Plasma.
- Keeping any KDE application. Dolphin, Okular, Gwenview, Spectacle, KWallet
  and KDE Connect go with Plasma. The niri module brings Nautilus for file
  dialogs. A KDE app comes back only as a standalone package if the owner
  asks for it.
- Keeping app logins across the switch. Slack and other Electron apps key
  their stored login to the desktop's secret store, so one re-login after
  the switch is expected (not tested) and accepted.
- Automatic window placement at login or on dock. Layouts change by day and
  by desk and are set by hand.
- Cleaning up the stale `nixosModules/desktops/hyprland` module.
- Carrying the setup to obsidian (thethreecfg). Keep it easy to copy, nothing
  more.

## Anti-goals

- Any change to the other hosts. malachite in particular has Plasma and
  fprintd and must keep both fingerprint fixes from commit `a2dc042`.
- Battery life worse than under Plasma: a plain suspend where
  suspend-then-hibernate is expected, the performance profile left on while
  on battery, or a laptop that stays awake in a bag.
- A lock screen or login screen that cannot be passed. See "Risks".
- A niri setup that silently depends on something only Plasma used to turn
  on. See "What Plasma was providing".

## How the owner works

- Apps: kitty (often several windows, each on a different zellij session),
  Firefox (often several windows, one per task), Slack.
- Usual layout on a wide screen: Firefox 1/4, kitty 1/2, Slack 1/4. Sometimes
  two kitty windows at 1/4 each in the middle. This changes by day and desk.
- Starting fresh on keys: happy to learn new ones, and no sway muscle memory
  or config remains.
- On macOS uses Rectangle for 1/2, 1/3, 1/4 placement.

## Desks and monitors

| Place         | Screens                                               | Lid    | Column width steps                                               |
| ------------- | ----------------------------------------------------- | ------ | ---------------------------------------------------------------- |
| Undocked      | laptop panel                                          | open   | 1/2, 2/3, full                                                   |
| Home          | two 4K monitors on a KVM, one landscape, one portrait | either | landscape: 1/3, 1/2, 2/3, full. portrait: full width only        |
| Work          | one ultrawide on a USB-C dock                         | closed | 1/4, 1/3, 1/2                                                    |
| Meeting rooms | unknown screen over USB-C, DisplayPort or HDMI        | open   | niri defaults; extends by default, mirror on a key (`wl-mirror`) |

Known so far, read from EDID on 2026-11-23 while docked at work:

| Screen       | Identity                                           | Connector | Mode            | Scale                 |
| ------------ | -------------------------------------------------- | --------- | --------------- | --------------------- |
| Work monitor | Samsung (`SAM`) Odyssey G95NC, serial `HNTY301614` | `DP-1`    | 7680x2160 @ 120 | 1.0 (owner's choice)  |
| Laptop panel | CSOT (`CSW`) `MND508ZB1-1`, no serial              | `eDP-1`   | 2880x1920 @ 120 | 1.7 (as under Plasma) |

- Pin external monitors by manufacturer, model and serial, not by connector,
  so settings follow the monitor across ports. The laptop panel is the
  exception: it has no serial and its connector never changes, so it is
  pinned as `eDP-1`. Use niri's per-output `layout`
  block for the width steps. The exact name string niri expects comes from
  `niri msg outputs`; the EDID values above are what to look for.
- On the portrait monitor a column is either one full-height window or
  windows stacked top and bottom. Both are native niri (consume a window into
  a column, expel it again) and have default keys.
- The home monitors are not known yet. Fill them in from `niri msg outputs`
  the first time ilmenite is plugged in there. Scale, position and rotation
  are decided then, with the owner.

## Keys

Use niri's default bindings unchanged. The owner is starting fresh and does
not want old habits carried over; do not remap a default without being asked.
For reference, the defaults that matter most for the layouts above:

| Keys                    | Default action                       |
| ----------------------- | ------------------------------------ |
| Super+arrows            | focus                                |
| Super+Ctrl+arrows       | move the window                      |
| Super+Shift+arrows      | focus the other monitor              |
| Super+Shift+Ctrl+arrows | move the window to the other monitor |
| Super+R                 | cycle the column width steps         |
| Super+F                 | maximize the column                  |

The one unavoidable difference: some defaults launch programs this setup
does not install (alacritty, fuzzel, swaylock, `wpctl`, `brightnessctl`,
`playerctl`). Keep the same keys and point them at kitty and Noctalia's
launcher, lock screen and media commands. Brightness, volume, mic-mute and
media keys go through `noctalia msg` so they show its on-screen display, and
must work while locked. The lock key must also work while locked: it is the
keyboard way to bring the prompt back if the lock screen's process dies
(see "Risks"). The default Super+Alt+S bind toggles the Orca screen reader,
which is not installed; it is left as a dead key. niri's defaults bind no
keyboard-backlight key and none is added. Keys for things niri has no
default for (session menu, clipboard history, mirroring with `wl-mirror`,
keep-awake) are chosen with the owner during tuning.

**Power button (builder's call, for the owner to veto).** niri takes the
power button over by default and calls a plain suspend, which never
hibernates. Turn that off (`input { disable-power-key-handling }`) and set
logind's `HandlePowerKey` to `suspend-then-hibernate`, so a short press
sleeps the same way the lid does. logind's own default would be power off.

Workspaces stay dynamic. No window rules pin kitty, Firefox or Slack anywhere.

## Login screen

Noctalia's greeter (`services.displayManager.noctalia-greeter`, a greetd
greeter in nixpkgs) replaces SDDM on ilmenite. Chosen by the owner over
keeping SDDM (known to work with fingerprint, but a Qt program that loses its
Plasma theme) and over a text-mode greeter (tuigreet).

- The login screen takes the password only (owner's decision, 2026-11-23).
  The owner logs in by password after a boot and uses the finger to unlock
  and for sudo. greetd's PAM service is `auth substack login`, the same as
  SDDM's, and today `login` has `pam_fprintd` first: PAM runs one step at a
  time, so a typed password is only checked after the finger attempt ends.
  The journal for the SDDM login on 2026-11-22 shows it: password submitted
  at 20:11:01, "Verification timed out" at 20:11:33, session opened then.
  With `pam_fprintd` out of `login` (see "Lock screen and fingerprint") the
  password is checked at once and gnome-keyring is unlocked by the login.
- If the greeter crashes without starting a session, greetd is not restarted
  and the screen stays blank. The way out is Ctrl+Alt+F2, a console login,
  and `sudo systemctl restart greetd`, or the previous generation.
- The greeter keeps state in `/var/lib/noctalia-greeter`, which is not on
  ilmenite's impermanence list. `noctalia msg greeter-sync` copies wallpaper,
  colours and monitor layout from the shell to the greeter through polkit;
  `passwordlessSyncUsers` exists for that.
- `/var/lib/sddm` on the impermanence list becomes unused.

## Power policy

The suspend-then-hibernate machinery in
`nixosConfigurations/ilmenite/hibernation.nix` is systemd's and is reused as
is, with one change requested by the owner: the hibernate delay drops from
3 h to 30 min (`HibernateDelaySec` and the matching `SuspendEstimationSec`).
On battery the laptop wakes once, 30 min after suspending, and hibernates. On
AC nothing puts it to sleep by itself (the lid and the idle timer are both
ignored), so the periodic check only matters after a manual suspend while
plugged in: `HibernateOnACPower = false` makes systemd re-arm the timer at
each wake, so that laptop now wakes briefly every 30 min instead of every 3 h,
and hibernates at the first check after it is unplugged. Update the comments
in that file to match.

What Plasma's power daemon provides today through `/etc/xdg/powerdevilrc`,
and what niri must match:

| State       | Power profile | Idle                | Lid close              |
| ----------- | ------------- | ------------------- | ---------------------- |
| On AC       | performance   | never sleeps        | nothing                |
| On battery  | balanced      | sleeps after 10 min | suspend-then-hibernate |
| Battery low | balanced      | as on battery       | hibernates at once     |

With Plasma off, the `powerdevilrc` block in `hibernation.nix` is dead
config on ilmenite. Remove it and rewrite the comments around it to describe
the new arrangement.

### Approaches considered

- **A. System-level, independent of the desktop (chosen).** A small system
  unit triggered by the AC adapter's udev event sets performance on AC and
  balanced on battery, also once at boot. Lid stays with logind, whose
  settings already exist. Idle sleep is a Noctalia idle behaviour whose
  command sleeps only when on battery. Low battery relies on systemd. Chosen
  because battery life should not depend on which desktop or shell is
  running.
- **B. Noctalia hooks only.** Plug and unplug hooks in the home config call
  `noctalia msg power-set`. Least code, but only works while Noctalia runs,
  and trusts UPower's view of the adapter, which is the view that went stale
  on unplug before the `acad-reread` udev rule.
- **C. Keep Plasma's power daemon running under niri.** Today's exact
  behaviour with no new policy code, but not known to work outside Plasma,
  and Plasma is being removed.

### Details of A

- **Profile.** The unit reads `/sys/class/power_supply/ACAD/online` itself
  and sets the profile through power-profiles-daemon. It runs on every
  adapter event, once at boot and on every resume (the charger can change
  while asleep). The stale-event problem that the `acad-reread` rule exists
  for is handled inside the unit: it sets the profile, waits two seconds,
  reads the adapter again and sets it again. A start request that arrives
  while the unit is still running is merged by systemd and would not rerun
  it, so the unit cannot rely on the re-emitted event alone. At boot it must
  hang off `graphical.target`: power-profiles-daemon orders itself after
  `multi-user.target`, so a unit wanted by `multi-user.target` and ordered
  after the daemon forms a loop that systemd breaks by dropping the unit.
  Like PowerDevil, it overwrites a manually chosen profile at the next
  adapter event.
- **Lid.** logind already has `HandleLidSwitch = suspend-then-hibernate` and
  `HandleLidSwitchExternalPower = ignore`. Under Plasma, PowerDevil took the
  lid over; under niri nothing does, so logind's settings apply. Expected,
  not yet tested. Docked at work with the lid closed is on AC, so the lid is
  ignored and the session keeps running on the external screen. logind
  checks three settings in order: `HandleLidSwitchDocked` (default `ignore`)
  when an external screen is enabled, then `HandleLidSwitchExternalPower`
  on AC, then `HandleLidSwitch`. So a closed lid on battery with a live
  external screen is ignored too, until that screen is blanked or
  unplugged; this is how the machine already behaves and is left alone.
  logind ignores the lid for 30 s after boot and after every resume.
- **Suspend means suspend-then-hibernate.** Noctalia's own suspend is plain
  `systemctl suspend`. Set its suspend command override to
  `systemctl suspend-then-hibernate`, so the session menu and every built-in
  suspend action take the battery-saving path.
- **Idle.** Noctalia has no AC check of its own, and it runs an idle
  behaviour once per idle period: a command that checks the adapter at the
  10 minute mark and exits would never notice the charger being pulled
  afterwards. So the idle behaviour at 600 s starts a small waiter that
  keeps checking until the laptop is on battery and then sleeps, and the
  behaviour's resume command stops the waiter when the owner comes back.
  `lockscreen.lock_before_suspend` (default true) covers locking.
  Screen-off and lock on idle are tuning choices; default them to screen off
  at 5 min and lock at 10 min on both AC and battery unless the owner says
  otherwise.
- **Presenting.** Slides hold no idle inhibitor (a playing video does), so
  on battery the screen would blank at 5 min and the laptop sleep at 10 min
  mid-talk. Noctalia's keep-awake toggle (`caffeine`) blocks all idle
  behaviours. It gets a key or a bar button during tuning; this is required,
  not optional.
- **Low battery.** systemd's suspend-then-hibernate skips the suspend and
  hibernates directly when the battery is discharging at 5 % or below. This
  replaces PowerDevil's "hibernate at once on lid close at 10 % or below".
  The owner accepted 5 % over an extra script.
- **Critical battery while awake (builder's call, for the owner to veto).**
  With PowerDevil gone the only actor is UPower, which on ilmenite is at its
  defaults: `CriticalPowerAction=HybridSleep` at `PercentageAction=2`. Hybrid
  sleep (write the image, then suspend to RAM instead of powering off) has
  never been tested on this machine; hibernate has. Set
  `services.upower.criticalPowerAction = "Hibernate"` and leave the
  thresholds alone. Not tested by draining the battery; say so in the
  report.

## Lock screen and fingerprint

Noctalia's lock screen checks the password against the `login` PAM service
and drives the fingerprint reader itself over D-Bus. ilmenite's `login`
service has `pam_fprintd` first, and the two cannot share the reader.

- **Chosen (owner's decision, 2026-11-23):** keep Noctalia's fingerprint on
  and set `security.pam.services.login.fprintAuth = false`. `login` is the
  service behind the greeter, the text console and Noctalia's lock screen,
  so all three become password-only at the PAM level, and the lock screen's
  finger unlock comes from Noctalia driving the reader itself. sudo and
  polkit have their own services and keep fingerprint. Noctalia is the
  stock nixpkgs package. Lost: finger login at the greeter after a logout,
  and at a text console.
- **Fingerprint after sleep is a blocker (owner's decision).** The plumbing
  half is not done until a finger unlocks the niri session after a resume,
  including the case where a scan was waiting when sleep began. If
  Noctalia's own fingerprint handling cannot be made to pass that test,
  stop and bring the options to the owner (for example a different lock
  screen that goes through `pam_fprintd`); do not ship password-only.
- **The fprintd stop on resume is not carried over to niri.** It lives in
  the Plasma desktop module (commit `a2dc042`), which is off on this host,
  and it stays there for malachite together with the `kde-fingerprint` fix.
  Under Noctalia it is expected to do harm: Noctalia's fingerprint code
  deliberately makes no fprintd call while the system is going to sleep and
  re-arms the reader as soon as it resumes, and it does not retry if fprintd
  disappears under it. A stop that lands moments after resume would kill
  the daemon it just re-armed. The fprintd bug the stop was written for is
  triggered by a release call during suspend, which `pam_fprintd` makes and
  Noctalia does not. This is read from source, not observed; the sleep test
  decides. A fingerprint prompt from sudo or polkit that is waiting when
  sleep starts can still trigger the fprintd bug; that case is rare and
  accepted.
- **Known limits of Noctalia's fingerprint, from its source.** Three
  non-matching touches end fingerprint for that lock; so does a refused
  claim, for example while a sudo fingerprint prompt holds the reader. One
  failed password attempt re-arms it.
- **Rejected:** a PAM service of its own for the lock screen, by building
  Noctalia with `-Dpam_service=noctalia`. It keeps finger login at the
  greeter, but the package is then compiled locally on every nixpkgs bump,
  a typed password at the greeter still waits out the fingerprint step, and
  a finger login leaves gnome-keyring locked. This was the design until the
  owner said they log in by password.
- **Rejected:** turning Noctalia's fingerprint off and leaving `pam_fprintd`
  in `login`. Expected, not tested: every password unlock would first wait
  on `pam_fprintd`, and a finger alone would not unlock.

## What Plasma was providing

`services.desktopManager.plasma6` turns these on, and the repo's Plasma
module adds SDDM. With both off on ilmenite, each needs a decision: provided
some other way, or knowingly dropped. Build the system with Plasma off and
diff the enabled services and the system closure against the current one to
catch anything not on this list.

| Provided by Plasma today                              | Under niri                                                                 |
| ----------------------------------------------------- | -------------------------------------------------------------------------- |
| power-profiles-daemon, UPower                         | required; nixpkgs `programs.noctalia.recommendedServices.enable` sets both |
| NetworkManager, bluetooth                             | already set by the repo; also covered by `recommendedServices`             |
| SDDM                                                  | Noctalia greeter                                                           |
| polkit agent, notifications, lock screen, OSDs        | Noctalia                                                                   |
| xdg portals (KDE)                                     | niri module: gnome and gtk portals                                         |
| KWallet as the secret service                         | gnome-keyring, the niri module's default                                   |
| Xwayland                                              | `xwayland-satellite`, from home-manager's niri module                      |
| pipewire, libinput, fonts                             | check; the repo's audio and font features probably cover them              |
| udisks2, fwupd, accounts-daemon, dconf, fuse, geoclue | keep udisks2, fwupd and dconf; builder's call on the rest                  |
| pinentry-qt, ksshaskpass defaults                     | home gpg config already names `pinentry-qt`; check ssh askpass is unused   |
| cursor and icon themes (Breeze)                       | pick a cursor theme; shared by the greeter, niri and GTK apps              |
| KDE apps                                              | dropped, see "Non-goals"                                                   |

Found by evaluating the planned config (reviewer, 2026-11-23); none of these
shows up in a diff of unit files, so each is set explicitly:

- `services.libinput.enable` goes from true to false, which drops libinput's
  udev rules (device quirks for the touchpad). Set it to true.
- gnome-keyring brings `services.gnome.gcr-ssh-agent` with it by default.
  The owner's SSH agent is gpg-agent. Set it to false.
- `programs.gdk-pixbuf.modulePackages` loses librsvg, which GTK apps use for
  SVG icons. Add it back.
- `login` gains `pam_gnome_keyring`. With the password-only login screen the
  keyring is unlocked by the login itself. Not tested.

## Structure

Follow `CLAUDE.md`. Prefer the upstream modules; all of them exist at the
pin.

| Piece                                | Where                                                              | Uses                                                |
| ------------------------------------ | ------------------------------------------------------------------ | --------------------------------------------------- |
| niri session, greeter, services      | `nixosModules/desktops/niri/module.nix`, `theonecfg.desktops.niri` | nixpkgs `programs.niri`, `noctalia-greeter`, greetd |
| `login` without the fingerprint step | same module                                                        | `security.pam.services.login.fprintAuth`            |
| Power profile unit, hibernate delay  | ilmenite host config, next to `hibernation.nix`                    | udev, systemd, power-profiles-daemon                |
| niri config                          | `homeModules/programs/niri/module.nix`, `theonecfg.programs.niri`  | home-manager `wayland.windowManager.niri`           |
| Noctalia config                      | `homeModules/programs/noctalia/module.nix`                         | home-manager `programs.noctalia`                    |
| Enabling                             | ilmenite's NixOS and home configurations only                      | not the shared desktop profiles                     |

- No new flake inputs.
- The shared desktop profile sets `theonecfg.desktops.plasma.enable` with
  `mkDefault true`. ilmenite sets it to `false` and enables niri; the
  profile and the other hosts are not touched.
- Noctalia runs as home-manager's user service, so it is restarted if it
  crashes. That service is wanted by `graphical-session.target`, which a
  Plasma session also reaches, and the home configuration is not rolled
  back with the system. Restrict the unit to niri sessions
  (`ConditionEnvironment=XDG_CURRENT_DESKTOP=niri`; niri imports that
  variable into the user manager), so it stays out of the Plasma session
  during the switch-over and in the fallback generation, where it would
  run as a second shell on top of Plasma with its idle behaviours armed.
- The cursor theme is set through home-manager's `home.pointerCursor` as
  well as niri's `cursor` block. A Noctalia started by systemd, and the apps
  its launcher starts, only get the theme from the session environment.
- Monitor pinning is per-host data. Keep it where ilmenite's home config can
  set it, not hard-coded in the shared niri module.
- Home configurations are standalone (`homeConfigurations`), applied with
  home-manager, separately from the NixOS rebuild. Order the switch so the
  home config with niri and Noctalia is in place before the first niri
  login.

## Tuning workflow

niri and Noctalia both reload their config on save, and a home-manager
managed config is a read-only store link. For the tuning half, the owner
edits live copies in the running session; once a setting has settled it is
written into the Nix modules and the live copy is dropped. How the live copy
is arranged (a temporary unmanaged file, an out-of-store link) is the
builder's choice. The end state has no unmanaged config.

Noctalia's settings GUI writes overrides to a `settings.toml` in its state
directory, on top of the Nix-rendered `config.toml`. `noctalia config export`
prints the merged result, which is the way to carry GUI choices back into
Nix. Look and theme start from Noctalia's defaults and are tuned in the
session. `noctalia config validate` only warns about an unknown setting and
still exits 0, so a mistyped key builds and does nothing; every ported
setting is confirmed in `noctalia config export full`. Everyday toggles in
Noctalia's UI (theme mode, dock) write `settings.toml` again, so that file
can reappear; what must not live only there is anything decided in tuning.

## Verified facts the design depends on

Checked at the flake pin (nixpkgs 26.11.20261121.2786a2a) on 2026-11-22 and
2026-11-23. Re-verify after a pin bump.

- nixpkgs has `niri` 26.04 and `nixos/modules/programs/wayland/niri.nix`. The
  module registers the session, installs the portal config (gnome and gtk
  portals), and sets `services.gnome.gnome-keyring.enable` and
  `services.displayManager.defaultSession = "niri"` with `mkDefault`. With
  Plasma still enabled the two default sessions conflict at evaluation; with
  Plasma off there is one definition.
- nixpkgs has `noctalia` 5.6.0, a native program (cairo, pango, wayland,
  PAM, polkit, pipewire; no Qt), `programs.noctalia` NixOS and home-manager
  modules, and `noctalia-greeter` with
  `nixos/modules/services/display-managers/noctalia-greeter.nix`. The
  home-manager module renders `~/.config/noctalia/config.toml` from
  `settings` and validates it at build time. The NixOS module has
  `recommendedServices.enable` (NetworkManager, bluetooth, UPower,
  power-profiles-daemon, all `mkDefault`).
- `nixos/modules/services/display-managers/greetd.nix` declares
  `security.pam.services.greetd` as `auth substack login`. ilmenite's current
  `/etc/pam.d/sddm` is the same, and `/etc/pam.d/login` starts with
  `pam_fprintd`.
- `nixos/modules/services/desktop-managers/plasma6.nix` sets, among others:
  `services.power-profiles-daemon.enable` (`mkDefault`),
  `services.upower.enable`, `services.udisks2.enable`,
  `services.accounts-daemon.enable`, `services.fwupd.enable`,
  `services.pipewire.enable`, `services.libinput.enable`,
  `services.geoclue2.enable`, `programs.dconf.enable`,
  `programs.fuse.enable`, `programs.xwayland.enable`, the pinentry and ssh
  askpass defaults, fonts, icon and cursor themes, and the KDE portal.
- Noctalia 5.6.0 source: the lock screen authenticates through a helper
  against the PAM service fixed at build time (`meson_options.txt`,
  `pam_service`, default `login`); the nixpkgs package does not override it.
  `src/shell/lockscreen/lock_screen.cpp` says that with fingerprint enabled
  `pam_fprintd` must be stripped from that service, because Noctalia drives
  the reader itself and the two cannot share it.
- Noctalia 5.6.0 source, `src/shell/session/session_action_runner.cpp`: the
  built-in suspend runs `systemctl suspend` (plain suspend) unless the
  session power config carries a `suspend` command override.
- `noctalia config export full` shows these defaults: `[idle]` behaviours
  `lock`, `screen-off`, `lock-and-suspend`, all disabled, each with
  `timeout`, `action`, `command`, `resume_command`; `[lockscreen]` with
  `fingerprint = true` and `lock_before_suspend = true`; `[hooks]` including
  `battery_plugged` and `battery_discharging`.
- `noctalia msg` has commands for brightness, volume, mic, keyboard
  backlight, power profile, screenshots, session actions, panels, DPMS and
  `greeter-sync`.
- home-manager has `wayland.windowManager.niri` with `settings` (Nix to KDL),
  `extraConfig`, build-time config validation, and it installs
  `xwayland-satellite`.
- niri docs (`docs/wiki` in the 26.04 source): outputs are matched by
  connector or by "manufacturer model serial"; an `output` block can carry
  its own `layout` block; all connected monitors are turned on by default;
  the laptop panel is turned off and on with the lid; there is no built-in
  mirroring and `wl-mirror` is the documented route; `switch-events` can run
  commands on lid close and open.
- systemd 262 `src/sleep/sleep.c` and `src/shared/battery-util.c`:
  suspend-then-hibernate loops `while (battery_is_discharging_and_low() == 0)`
  with `BATTERY_LOW_CAPACITY_LEVEL 5`, and with `HibernateOnACPower=no` it
  resets the timer and keeps suspending while on AC.
- ilmenite's `/etc/UPower/UPower.conf`: `CriticalPowerAction=HybridSleep`,
  `PercentageAction=2`, `PercentageCritical=5`.
- `/home` is not on the impermanence list in `impermanence.nix`, so user
  config and keyrings persist. `/var/lib/sddm` is on it;
  `/var/lib/noctalia-greeter` is not.
- The home gpg module sets `pinentry.package = pkgs.pinentry-qt` itself.

## Not verified, to settle while building

- Whether Noctalia's fingerprint unlock works after a resume, both after a
  plain lid close and when a scan was waiting as sleep began, and after a
  resume from hibernate, where its claim on the reader may be stale. This
  is the blocker test.
- That logind acts on the lid under niri as described. Source shows neither
  niri nor Noctalia holds a lid inhibitor.
- What happens when Noctalia is restarted while the session is locked. Its
  destructor queues an unlock request before disconnecting; if niri
  receives it the session unlocks, if not niri stays locked with no prompt
  and Noctalia does not lock again by itself.
- Whether the adapter sends a change event on resume when the charger
  changed during sleep. The profile unit runs on every resume regardless.
- That resume from hibernate returns to the locked niri session. The
  hibernation setup was only verified with SDDM and Plasma.
- Whether `xdg-desktop-portal-gnome` and its Nautilus file chooser (niri
  module defaults) are acceptable, or `useNautilus = false` is preferred.
  Builder's call; default to the module's defaults.

## Risks

- **No second session to fall back to.** The way back is the previous NixOS
  generation in the systemd-boot menu, which still has Plasma and SDDM.
  Before the first switch, confirm that generation is listed and that the
  owner knows how to pick it. Do not garbage-collect it during the trial.
  Picking it in the menu lasts one boot; `sudo nixos-rebuild boot --rollback`, run from it, makes it the default again. The home
  configuration stays on the niri one, which is harmless there because
  Noctalia only starts in a niri session.
- **Locked out at the greeter or the lock screen.** Keep a text console
  login working (it uses `login`, which stays a plain password check), and
  before the first lock have a second way in: an SSH session from another
  machine or a logged-in console.
- **A lock screen with no prompt.** If Noctalia dies or restarts while the
  session is locked, niri keeps the screen locked (solid red) and Noctalia
  does not lock again by itself. `loginctl unlock-session` does nothing in
  that state. Locking again brings the prompt back: the lock key, which is
  bound to work while locked, or `loginctl lock-session` from the second
  way in.
- **Sleep regressions.** The hibernation setup was verified with eight
  hardware tests under Plasma. Under niri re-run at least: lid close on
  battery suspends and hibernates after the delay; lid close on AC does
  nothing; unplug sets balanced and plug sets performance; idle on battery
  sleeps and idle on AC does not; resume from hibernate returns to a locked
  niri session; fingerprint unlocks after each kind of resume.
- **Something Plasma provided goes missing unnoticed.** Covered by the
  closure and service diff under "What Plasma was providing".
- **Other hosts.** Their system closures must not change. Check by
  comparing each host's toplevel derivation path before and after.

## Verification

The owner drives every physical test (lid, plug, finger, docks, reboot). The
builder does not suspend, lock, log out or reboot the machine. After each
test the builder reads the journal and reports what it shows.

Done means: the builds and `nix flake check` pass; the other hosts'
derivations are unchanged; the tests under "Risks" pass on the hardware,
including the fingerprint blocker; login time is measured for both desktops;
and each desk has been visited once and its monitors pinned. The home desk
pinning may land after the rest, when ilmenite is next plugged in there.

## Measurements

Plasma, generation 9 (the fallback; identical to the base commit's build),
login of 2026-11-22 after a cold boot, read from the journal on 2026-11-23:

| Step                                                           | Time         | Since password submitted |
| -------------------------------------------------------------- | ------------ | ------------------------ |
| Password submitted at SDDM                                     | 20:11:01.009 | 0                        |
| `pam_fprintd` "Verification timed out", password then checked  | 20:11:33.148 | 32.1 s                   |
| logind "New session '2' of user 'djacu'"                       | 20:11:33.269 | 32.3 s                   |
| "Reached target Current graphical user session"                | 20:11:35.056 | 34.0 s                   |
| last dense burst of plasmashell and service start-up log lines | 20:11:42     | about 41 s               |
| start-up logging quiet                                         | 20:11:48     | about 47 s               |

- Session to `graphical-session.target`, the measure the goal names: 1.8 s.
- That measure undercounts Plasma: the shell kept starting for roughly 9 to
  15 s after the session opened. "Usable" is not visible in the journal, so
  record the same two figures for niri (target reached; start-up logging
  quiet) and the owner's impression next to them.
- About two thirds of this login was the fingerprint wait, which is removed
  by `security.pam.services.login.fprintAuth = false` regardless of desktop.
- Owner's impression of Plasma's start-up: not yet recorded.

## Service diff

The Plasma system (generation 9) against the niri system built on
2026-11-24, from `nix store diff-closures` and the unit, udev and PAM
directories of the two builds. Closure size goes from 9.9 GiB to 6.6 GiB;
405 packages leave and 51 arrive.

Still present, checked by name: pipewire, wireplumber, NetworkManager,
bluez, udisks2, fwupd, UPower, power-profiles-daemon, fprintd, polkit, CUPS,
the fonts, libinput and its two udev rule files, librsvg.

Removed and not KDE's own:

| Removed                                                          | Came from                          | Under niri                                                                 |
| ---------------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------- |
| geoclue service and agent                                        | Plasma module                      | dropped; Noctalia's night light can take a fixed location if wanted        |
| `at-spi-dbus-bus` (accessibility bus), Orca, brltty              | Plasma module                      | dropped; GTK apps may log a warning about the missing bus                  |
| `70-printers.rules`, `configure-printer@`, system-config-printer | Plasma module, when printing is on | dropped; CUPS and the Brother driver stay, USB printers are not auto-added |
| `69-libmtp.rules`, `40-usb-media-players.rules`                  | KDE's MTP and media-player support | dropped with Dolphin; no phone file transfer over USB                      |
| openvpn, openconnect, strongswan, vpnc scripts                   | Plasma's network applet            | dropped; no VPN connection is configured in NetworkManager on ilmenite     |
| ddcutil                                                          | PowerDevil                         | dropped; Noctalia can use it for external monitor brightness if added      |
| Xwayland as a system package                                     | Plasma module                      | `xwayland-satellite` from the home config                                  |
| KDE and SDDM PAM services                                        | Plasma module                      | `greetd`; an unused `swaylock` service appears from the niri module        |
| pciutils, lsof, dmidecode, clinfo, vulkan-tools, wayland-utils   | KInfoCenter                        | dropped from the system closure                                            |

Added: niri, noctalia, noctalia-greeter, greetd, seatd, gnome-keyring, gcr,
nautilus with its dependencies (localsearch, gnome-autoar, gnome-user-share
with apache-httpd), xdg-desktop-portal-gnome, adwaita-icon-theme.

## Review changes

Four reviewers attacked this design and its plan on 2026-11-23 (power and
sleep; login and lock; Nix correctness; plan against spec). Each claim acted
on was checked against the source first. What changed here as a result:

| Finding                                                                                      | Change                                                          |
| -------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| The profile unit formed a boot ordering loop with power-profiles-daemon and would be dropped | hangs off `graphical.target`                                    |
| A second adapter event inside a second could be merged and lost                              | the unit re-reads after two seconds itself; also runs on resume |
| niri's power button is a plain suspend                                                       | niri's handling off, logind `HandlePowerKey` set                |
| An idle check that runs once misses a later unplug                                           | the idle behaviour starts a waiter, stopped on resume           |
| Slides hold no idle inhibitor                                                                | keep-awake toggle is required; tested                           |
| The fprintd stop on resume would race Noctalia's re-arm                                      | not carried over to niri                                        |
| Restarting Noctalia while locked leaves no prompt, and `unlock-session` cannot help          | lock key works while locked; recovery rewritten                 |
| Noctalia's service would start under Plasma, including in the fallback generation            | unit restricted to niri sessions                                |
| libinput rules, librsvg and an unwanted SSH agent change silently with Plasma off            | set explicitly                                                  |
| A stopwatch login time measures the fingerprint timeout                                      | measured from the journal                                       |
| `noctalia config validate` does not reject unknown keys                                      | ported settings are confirmed in the export                     |

Rejected or left alone, with the reason:

- A closed lid on battery with a live external screen is ignored by logind's
  `HandleLidSwitchDocked` default. True, but it is today's behaviour and
  rare for the owner; documented under "Details of A", not changed.
- Fingerprint login at the greeter needed `allow_empty_password`, and the
  dedicated PAM service needed a rebuilt package under a repo-prefixed
  name. Both findings were correct and both are moot: the owner then chose
  a password-only login screen, which removes the package variant
  altogether (see "Lock screen and fingerprint").
- Locking from a text console may be refused the fingerprint reader by
  polkit. The reviewer did not verify it and it only affects a recovery
  path; left for the hardware tests to show.

## Left to the builder

- Module internals and option names beyond those given.
- The mechanism for the power profile unit (udev `SYSTEMD_WANTS`, a `RUN`
  that starts a unit, or similar) and the exact command used to set the
  profile.
- The cursor theme, unless the owner names one during tuning.
- How the live-tuning copies are arranged.
- Commit split. Suggested: hibernate delay; power profile unit and critical
  action; niri module with greeter and PAM service; ilmenite switch-over and
  powerdevilrc removal; home modules; then tuning results as they settle.
