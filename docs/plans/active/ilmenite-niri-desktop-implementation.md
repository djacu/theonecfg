# ilmenite niri Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Plasma and SDDM on ilmenite with niri, the Noctalia shell
and the Noctalia greeter, keeping fingerprint, sleep and battery behaviour.

**Architecture:** A new NixOS module `theonecfg.desktops.niri` turns on
nixpkgs' `programs.niri`, `programs.noctalia` and
`services.displayManager.noctalia-greeter`, and takes the fingerprint step
out of the `login` PAM service. Power policy that PowerDevil used to provide moves to
a system unit on ilmenite. Two home modules render the niri and Noctalia
configs through home-manager's upstream modules. Tasks 2 to 6 are Nix and are
verified by building; Task 7 is the hardware switch-over driven by the owner;
Task 8 is live tuning with the owner.

**Tech Stack:** NixOS unstable (nixpkgs 26.11.20261121.2786a2a), niri 26.04,
noctalia 5.6.0, noctalia-greeter 1.7.1, greetd, home-manager (standalone),
systemd 262, power-profiles-daemon 0.30, UPower, fprintd 1.94.5.

**Spec:** `docs/plans/active/ilmenite-niri-desktop.md`. Read it first; this
plan argues from it and does not repeat its reasoning. Its "Review changes"
section lists what four adversarial reviews changed on 2026-11-23.

## Global Constraints

- Only ilmenite changes. The toplevel derivations of argentite, cassiterite,
  malachite, scheelite, uraninite and test-vm, and the home activation
  packages of every host but ilmenite, must be identical to the base commit
  `a2dc04208491718d1174647437000514d4693a94`.
- No new flake inputs.
- Follow `CLAUDE.md`: declare `options.theonecfg.<path>.enable` with
  `mkEnableOption`, wrap config in `mkIf cfg.enable`, and `inherit` those
  from `lib.options` and `lib.modules` in a `let` block, as
  `nixosModules/desktops/plasma/module.nix` does. New modules auto-import
  from `<dir>/module.nix`. Use `.#<attr>`, never `nixpkgs#`.
- A flake only sees files git knows about. After creating a file, run
  `git add <file>` before any `nix` command. Every "create" step below ends
  with that.
- Use niri's default key bindings unchanged. Do not remap a default unless
  the owner asks.
- "Suspend" always means `systemctl suspend-then-hibernate`.
- Fingerprint unlock after a resume is a blocker. If it does not work, stop
  and ask the owner.
- The builder never suspends, locks, logs out, reboots or switches the
  machine. The owner runs every `nixos-rebuild`, `home-manager switch` and
  physical test. The builder reads the journal afterwards.
- On any failure or deviation from this plan, stop and ask the owner. Do not
  improvise a fix.
- Do not refactor or tidy code this plan does not name. The stale
  `nixosModules/desktops/hyprland` module stays. The fingerprint fixes in
  `nixosModules/desktops/plasma/module.nix` stay as they are.
- Commits: plain engineer voice, no em dashes, subject prefixed with the
  attribute path as in `git log`, and an
  `Assisted-by: Claude Code (<model id>)` trailer. No `Co-Authored-By`.
  Commit on `djacu/niri-desktop` only.
- In a Claude Code worktree session the harness refuses shell commands
  containing the word `eval` (so `nix eval`), `git -C`, and compound
  commands that mix git with other commands. Every check below uses
  `nix build`, `nix path-info` or files in a build output, and runs git as
  plain separate commands.
- `/tmp` is on the root dataset that is rolled back at every boot. Nothing
  this plan needs later may live only in a scratch directory; results go
  into the design doc.

## Review Focus

Conditions the spec implies that no build can prove. Each is pinned to a
hardware test in Task 7.

1. Presenting on battery: the laptop must not blank or sleep mid-talk with
   keep-awake on, and must sleep without it. Tests 13 and 14.
1. Power source changes with nobody at the keyboard: unplugging while
   already idle, unplugging with the lid closed, and plugging in while
   asleep must each end in the right state. Tests 9, 12, 15, 16.
1. Noctalia restarting while the session is locked: the owner must be able
   to get the prompt back from the keyboard. Test 6.
1. Fingerprint after every kind of resume, including a scan that was
   waiting when sleep began. Blocker. Tests 10, 11, 17.
1. A cold boot on battery must not come up on the performance profile.
   Test 18.

______________________________________________________________________

### Task 1: Baseline

No code. Produces the numbers later comparisons use.

**Files:**

- Modify: `docs/plans/active/ilmenite-niri-desktop.md` (new "Measurements"
  section)

- [ ] **Step 1: Confirm the invariance check works from the base commit**

For each host in `argentite cassiterite malachite scheelite uraninite test-vm` run both

`nix path-info --derivation .#nixosConfigurations.<host>.config.system.build.toplevel`
`nix path-info --derivation ".?rev=a2dc04208491718d1174647437000514d4693a94#nixosConfigurations.<host>.config.system.build.toplevel"`

and for each of `argentite-djacu cassiterite-djacu malachite-djacu scheelite-djacu` the same pair with
`homeConfigurations.<name>.activationPackage`.
Expected: each pair prints the same path. This pair of commands is "the
invariance check" in later tasks; nothing needs storing.

- [ ] **Step 2: Build the Plasma system from the base commit, for diffing**

Run: `nix build --no-link --print-out-paths ".?rev=a2dc04208491718d1174647437000514d4693a94#nixosConfigurations.ilmenite.config.system.build.toplevel"`
Later tasks call this output `$BASE`. It can be rebuilt with the same
command at any time.

- [ ] **Step 3: Plasma's login time and the fallback generation**

Ask the owner to paste the output of
`nixos-rebuild list-generations | head -5` and, after their next ordinary
login to Plasma (no extra reboot needed), of:

```sh
journalctl -b 0 --no-pager -o short-precise | grep -E "New session .* of user djacu|Reached target .*graphical-session"
```

The login time is the gap between the last "New session" line for the
graphical login and the "Reached target" line after it. Record the time,
the generation number of the running system, and the owner's own impression
of how long Plasma takes, in the design doc under "Measurements". If the
grep shows no "Reached target" line, stop and ask.

- [ ] **Step 4: Commit the two plan documents**

Commit: `docs: add the ilmenite niri desktop design and plan`

______________________________________________________________________

### Task 2: Hibernate delay of 30 minutes

**Files:**

- Modify: `nixosConfigurations/ilmenite/hibernation.nix` (the
  `systemd.sleep.settings.Sleep` block and the comment above it)

- [ ] **Step 1: Change the values**

`HibernateDelaySec = "30min"` and `SuspendEstimationSec = "30min"`.
`HibernateOnACPower = false` stays. Rewrite the comment above the block to
say: on battery, s2idle, then one wake at 30 min that hibernates; on AC
nothing sleeps the laptop by itself, and after a manual suspend on AC it
wakes briefly every 30 min, re-arms and suspends again until unplugged.

- [ ] **Step 2: Build and check the rendered file**

Run: `out=$(nix build --no-link --print-out-paths .#nixosConfigurations.ilmenite.config.system.build.toplevel) && cat $out/etc/systemd/sleep.conf`
Expected: `HibernateDelaySec=30min`, `SuspendEstimationSec=30min`,
`HibernateOnACPower=false`.

- [ ] **Step 3: Format, check, commit**

Run: `nix fmt` then `nix flake check`
Expected: `all checks passed!`
Commit: `nixosConfigurations.ilmenite: hibernate 30 minutes after suspend`

______________________________________________________________________

### Task 3: Power profile unit, power button, critical battery action

**Files:**

- Create: `nixosConfigurations/ilmenite/power.nix`
- Modify: `nixosConfigurations/ilmenite/default.nix` (add `./power.nix` to
  `imports`, after `./impermanence.nix`)

**Interfaces:**

- Produces: system unit `power-profile-ac.service`; Task 7 tests it by name.

- [ ] **Step 1: Write `power.nix`, then `git add` it**

A plain module `{ config, pkgs, ... }: { ... }` containing:

- `services.power-profiles-daemon.enable = true;` and
  `services.upower.enable = true;`, stated because Plasma's module used to
  set them.
- `services.upower.criticalPowerAction = "Hibernate";` with a comment: the
  default is hybrid sleep, never tested here; hibernate is; thresholds are
  left at UPower's defaults; not tested by draining.
- `services.logind.settings.Login.HandlePowerKey = "suspend-then-hibernate";`
  with a comment: niri's own power-button handling is turned off in the
  niri config because it calls a plain suspend.
- `systemd.services.power-profile-ac`:
  `description = "Set the power profile from the AC adapter state"`,
  `wantedBy = [ "graphical.target" ]`, `after` and `requires`
  `power-profiles-daemon.service`, `serviceConfig.Type = "oneshot"`,
  `path = [ pkgs.power-profiles-daemon ]`, and this script:

```sh
set_profile() {
  read -r online < /sys/class/power_supply/ACAD/online
  if [ "$online" = 1 ]; then profile=performance; else profile=balanced; fi
  powerprofilesctl set "$profile"
}
set_profile
# The adapter's first event can carry a stale state, and a start request
# that arrives while this is running is merged, not queued.
sleep 2
set_profile
```

Comment above the unit: PowerDevil used to do this. `graphical.target`,
not `multi-user.target`: the daemon orders itself after
`multi-user.target`, and a unit wanted by that target and ordered after
the daemon is dropped by systemd to break the loop.

- A udev rule through `services.udev.extraRules`:
  `SUBSYSTEM=="power_supply", KERNEL=="ACAD", ACTION=="change", RUN+="${config.systemd.package}/bin/systemctl --no-block start power-profile-ac.service"`

- `powerManagement.resumeCommands` with the same
  `systemctl --no-block start power-profile-ac.service` line and a comment:
  the charger can change while asleep.

- [ ] **Step 2: Build and check the outputs**

Run: `out=$(nix build --no-link --print-out-paths .#nixosConfigurations.ilmenite.config.system.build.toplevel)`
Then:

- `grep CriticalPowerAction $out/etc/UPower/UPower.conf` prints
  `CriticalPowerAction=Hibernate`.

- `grep HandlePowerKey $out/etc/systemd/logind.conf` prints
  `HandlePowerKey=suspend-then-hibernate`.

- `cat $out/etc/systemd/system/power-profile-ac.service` shows
  `Type=oneshot` and `Requires=power-profiles-daemon.service`.

- `ls $out/etc/systemd/system/graphical.target.wants/ | grep power-profile-ac`
  prints the unit, and the same `ls` on `multi-user.target.wants` does not.

- `grep -r power-profile-ac $out/etc/udev/rules.d/` prints the rule.

- `SYSTEMD_UNIT_PATH=$out/etc/systemd/system: systemd-analyze verify --man=no graphical.target 2>&1 | grep -i cycle`
  prints nothing. (A reviewer reproduced a cycle this way with the unit
  wanted by `multi-user.target`.)

- [ ] **Step 3: Format, check, commit**

Run: `nix fmt` then `nix flake check`
Commit: `nixosConfigurations.ilmenite: set the power profile from the adapter state`

______________________________________________________________________

### Task 4: NixOS module `theonecfg.desktops.niri`

**Files:**

- Create: `nixosModules/desktops/niri/module.nix`

**Interfaces:**

- Produces: `theonecfg.desktops.niri.enable`; a `login` PAM service without
  `pam_fprintd`; session `niri` offered by the greeter. Task 5 enables the
  option. Noctalia is the stock `pkgs.noctalia` everywhere.

- [ ] **Step 1: Write the module, then `git add` it**

Under `mkIf cfg.enable`:

- `programs.niri.enable = true;`
- `programs.noctalia = { enable = true; recommendedServices.enable = true; };`
  Leave `programs.noctalia.systemd.enable` off; home-manager owns the user
  service (Task 6).
- `services.displayManager.noctalia-greeter` with `enable = true` and
  `cursorTheme.package = pkgs.adwaita-icon-theme` (`cursorTheme.name`
  defaults to `Adwaita`).
- `security.pam.services.login.fprintAuth = false;` with a comment: `login`
  is the service behind the greeter (greetd substacks it), the text console
  and Noctalia's lock screen. The lock screen drives the fingerprint reader
  itself and cannot share it with `pam_fprintd`; at the greeter the owner
  logs in by password, and with `pam_fprintd` first a typed password waited
  out a 30 s fingerprint timeout. sudo and polkit have their own services
  and keep fingerprint.
- One block with one comment, "Plasma's module used to turn these on":
  `services.libinput.enable = true;`, `services.udisks2.enable = true;`,
  `services.fwupd.enable = true;`, `programs.dconf.enable = true;`,
  `programs.gdk-pixbuf.modulePackages = [ pkgs.librsvg ];`
- `services.gnome.gcr-ssh-agent.enable = false;` with a comment: it comes
  on with gnome-keyring, which the niri module enables, and a second SSH
  agent is not wanted.

Do not copy the fprintd `resumeCommands` stop from the Plasma module. The
spec explains why ("Lock screen and fingerprint").

- [ ] **Step 2: Run the invariance check**

The module is not enabled anywhere yet. Run the Task 1 Step 1 pairs.
Expected: every pair identical.

- [ ] **Step 3: Format, check, commit**

Run: `nix fmt` then `nix flake check`
Commit: `nixosModules.theonecfg.desktops.niri: init`

______________________________________________________________________

### Task 5: Switch ilmenite's system config from Plasma to niri

**Files:**

- Modify: `nixosConfigurations/ilmenite/default.nix` (next to
  `theonecfg.profiles.desktop.enable`)

- Modify: `nixosConfigurations/ilmenite/hibernation.nix` (lid comment,
  `powerdevilrc` block, the `acad-reread` comment's mention of powerdevil)

- Modify: `nixosConfigurations/ilmenite/impermanence.nix`

- Modify: `docs/plans/active/ilmenite-niri-desktop.md` (new "Service diff"
  section)

- [ ] **Step 1: Enable niri, disable Plasma**

In `default.nix` add `theonecfg.desktops.plasma.enable = false;` and
`theonecfg.desktops.niri.enable = true;`. The desktop profile sets Plasma
with `mkDefault`, so a plain `false` wins.

- [ ] **Step 2: Remove the PowerDevil config and fix the comments**

In `hibernation.nix`: delete the `environment.etc."xdg/powerdevilrc".text`
block and its comment. Rewrite the lid comment to say logind handles the lid
at the login screen and in the niri session, since nothing takes it over. In
the `acad-reread` comment replace the sentence about powerdevil keeping the
AC profile with one naming `power-profile-ac.service` as a consumer of the
adapter events. Change nothing else in the file.

- [ ] **Step 3: Persist the greeter's state**

In `impermanence.nix` replace `"/var/lib/sddm"` with
`"/var/lib/noctalia-greeter"`.

- [ ] **Step 4: Build**

Run: `out=$(nix build --no-link --print-out-paths .#nixosConfigurations.ilmenite.config.system.build.toplevel)`
Expected: builds. If evaluation reports a conflicting or missing option,
stop and ask.

- [ ] **Step 5: Check the generated login and lock services**

- `grep '^auth' $out/etc/pam.d/login` has no `pam_fprintd` line and has a
  `pam_unix.so` line. `ls $out/etc/pam.d/` has no `noctalia`.

- `grep -c pam_fprintd $out/etc/pam.d/sudo` and the same on `polkit-1` each
  print at least `1`.

- `grep '^auth' $out/etc/pam.d/greetd` is `auth substack login`.

- `ls $out/etc/pam.d/` has no `sddm` and no `kde-fingerprint`.

- `cat $out/etc/systemd/system/greetd.service` names greetd's config file
  (in `/etc/greetd/` or a store path passed with `--config`); that file's
  default session command runs `noctalia-greeter-session`.

- `ls $out/etc/systemd/system/ | grep -c sddm` prints `0`.

- The script behind `$out/etc/systemd/system/sleep-actions.service`
  `ExecStop` contains `power-profile-ac.service` and does not contain
  `fprintd`.

- `ls $out/etc/systemd/user/ | grep -c gcr-ssh-agent` prints `0`.

- `ls $out/etc/udev/rules.d/ | grep -i libinput` prints at least one file.

- The cycle check from Task 3 Step 2 still prints nothing.

- [ ] **Step 6: Diff against the Plasma system for things that went missing**

Run `nix store diff-closures $BASE $out`, then
`diff <(ls $BASE/etc/systemd/system) <(ls $out/etc/systemd/system)`, the
same for `etc/systemd/user`, and `diff <(ls $BASE/etc/udev/rules.d) <(ls $out/etc/udev/rules.d)`.
Go through what was removed against the spec's "What Plasma was providing".
Write the review into the design doc under "Service diff": each removed
item that is not KDE's own, and what now provides it or that it is
knowingly dropped. Expected removals include SDDM, PowerDevil, KWallet,
kwin, the KDE portal, geoclue and orca. If pipewire, NetworkManager,
bluetooth, udisks2, fwupd, upower, power-profiles-daemon, fprintd, polkit,
fonts or a portal backend is missing, add the explicit option to the niri
module and rebuild. Anything else that looks like the owner would notice:
stop and ask.

- [ ] **Step 7: Run the invariance check**

Expected: every pair identical.

- [ ] **Step 8: Format, check, commit**

Run: `nix fmt` then `nix flake check`
Commit: `nixosConfigurations.ilmenite: replace Plasma with niri and Noctalia`

______________________________________________________________________

### Task 6: Home modules for niri and Noctalia

**Files:**

- Create: `homeModules/programs/niri/module.nix`
- Create: `homeModules/programs/noctalia/module.nix`
- Modify: `homeConfigurations/ilmenite/djacu/default.nix`

**Interfaces:**

- Consumes: `pkgs.noctalia`, `pkgs.niri`.

- Produces: `theonecfg.programs.niri.enable`,
  `theonecfg.programs.noctalia.enable`; transient user unit name
  `noctalia-battery-sleep.service`. Per-host monitor settings are set by the
  host's home config directly through
  `wayland.windowManager.niri.extraConfig`; there is no custom option for
  them.

- [ ] **Step 1: Write the niri module, then `git add` it**

Use the `CLAUDE.md` skeleton (the existing `kitty` module predates it; do
not copy its style). Under `mkIf`:

- `wayland.windowManager.niri.enable = true;` with `package = pkgs.niri`,
  `portalPackage = null` and `systemd.enable = false` (the NixOS module
  already installs the session units and the portals).

- Niri's shipped default config, minus its one line that starts a bar this
  setup does not install. Build it with `pkgs.runCommand`: fail unless
  `grep -qx 'spawn-at-startup "waybar"'` matches
  `${pkgs.niri.src}/resources/default-config.kdl`, then write the file
  without that exact line to `$out`. Put `include "<that path>"` first in
  `extraConfig` with `lib.mkBefore`. Do not use `enableDefaultConfig`.

- After the include, in `extraConfig`, KDL for:

  - `input { disable-power-key-handling }`
  - `binds` that keep niri's keys and repoint the programs:
    `Mod+T` spawns `kitty`; `Mod+D` runs
    `noctalia msg panel-toggle launcher`; `Super+Alt+L` runs
    `noctalia msg session lock` with `allow-when-locked=true`. Keep each
    bind's `hotkey-overlay-title` accurate.
  - Media keys, each with `allow-when-locked=true`, each running
    `noctalia msg` with: `XF86AudioRaiseVolume` `volume-up`,
    `XF86AudioLowerVolume` `volume-down`, `XF86AudioMute` `volume-mute`,
    `XF86AudioMicMute` `mic-mute`, `XF86MonBrightnessUp` `brightness-up`,
    `XF86MonBrightnessDown` `brightness-down`, `XF86AudioPlay`
    `media toggle`, `XF86AudioStop` `media stop`, `XF86AudioPrev`
    `media previous`, `XF86AudioNext` `media next`.
  - Noctalia's documented niri integration
    (`docs/user/compositor-settings/niri.mdx` in the Noctalia source): the
    floating window rule for `app-id="dev.noctalia.Noctalia"` and
    `debug { honor-xdg-activation-with-invalid-serial }`. Not the rounded
    corner rule, not the wallpaper options, not the extra binds; those are
    tuning.
  - `cursor { xcursor-theme "Adwaita"; xcursor-size 24; }`

- `home.pointerCursor = { package = pkgs.adwaita-icon-theme; name = "Adwaita"; size = 24; };`

- `home.packages = [ pkgs.wl-mirror ];`

- [ ] **Step 2: Write the Noctalia module, then `git add` it**

Under `mkIf`: `programs.noctalia.enable = true;`, `systemd.enable = true;`
(the package stays at the module's default, `pkgs.noctalia`), and
`systemd.user.services.noctalia.Unit.ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";`
with a comment: the unit is wanted by `graphical-session.target`, which a
Plasma session also reaches, and under Plasma (the fallback generation) it
would run as a second shell with its idle behaviours armed.

`settings`, written as a Nix attrset, with exactly:

```toml
[shell.session.power]
suspend = "<pkgs.systemd>/bin/systemctl suspend-then-hibernate"

[idle]
behavior_order = ["screen-off", "lock", "battery-sleep"]

[idle.behavior.screen-off]
action = "screen_off"
timeout = 300
enabled = true

[idle.behavior.lock]
action = "lock"
timeout = 600
enabled = true

[idle.behavior.battery-sleep]
action = "command"
timeout = 600
enabled = true
command = "<pkgs.systemd>/bin/systemd-run --user --collect --unit=noctalia-battery-sleep <waiter script>"
resume_command = "<pkgs.systemd>/bin/systemctl --user stop noctalia-battery-sleep.service"
```

The waiter is a `pkgs.writeShellScript` named `noctalia-battery-sleep`:

```sh
# Noctalia runs an idle command once per idle period, so wait here until the
# laptop is on battery. systemd-ac-power exits 0 on AC.
while systemd-ac-power; do sleep 30; done
systemctl suspend-then-hibernate
```

with both commands referenced from `pkgs.systemd` by store path. Leave
`lockscreen` at its defaults (`fingerprint = true`,
`lock_before_suspend = true`).

- [ ] **Step 3: Enable both on ilmenite and pin the known screens**

In `homeConfigurations/ilmenite/djacu/default.nix` add
`theonecfg.programs.niri.enable = true;`,
`theonecfg.programs.noctalia.enable = true;` and
`wayland.windowManager.niri.extraConfig` with two `output` blocks:

```kdl
output "eDP-1" {
    scale 1.7
    layout {
        preset-column-widths {
            proportion 0.5
            proportion 0.66667
            proportion 1.0
        }
    }
}

output "Samsung Electric Company Odyssey G95NC HNTY301614" {
    scale 1.0
    layout {
        preset-column-widths {
            proportion 0.25
            proportion 0.33333
            proportion 0.5
        }
    }
}
```

The Samsung name is the expected form (manufacturer, model, serial from
EDID) and is confirmed in Task 7, test 2. Add a comment saying so.

- [ ] **Step 4: Build; the niri config is validated at build time**

Run: `hm=$(nix build --no-link --print-out-paths .#homeConfigurations.ilmenite-djacu.activationPackage)`
Expected: builds. home-manager runs `niri validate` on the KDL, which
rejects bad syntax and unknown nodes. It also runs
`noctalia config validate`, but that only warns about unknown settings and
exits 0, so Step 5 is the real check for the TOML.

- [ ] **Step 5: Check the rendered files**

- `grep -c '^spawn-at-startup' <the included default-config path>` prints
  `0` (find the path on the `include` line of
  `$hm/home-files/.config/niri/config.kdl`).

- `grep -c 'disable-power-key-handling' $hm/home-files/.config/niri/config.kdl`
  prints `1`.

- Run
  `XDG_CONFIG_HOME=$hm/home-files/.config XDG_STATE_HOME=<empty scratch dir> $noc/bin/noctalia config export full`
  (`noc=$(nix build --no-link --print-out-paths .#noctalia)`) and read the
  output: `[shell.session.power]` has the
  `suspend` override ending in `systemctl suspend-then-hibernate`;
  `[idle.behavior.screen-off]`, `lock` and `battery-sleep` are enabled with
  timeouts 300, 600, 600 and the actions above; `battery-sleep` has both
  `command` and `resume_command`. A setting that was mistyped will be
  missing here even though the build passed.

- `grep -E 'ExecStart|ConditionEnvironment' $hm/home-files/.config/systemd/user/noctalia.service`
  shows `ExecStart=$noc/bin/noctalia` and
  `ConditionEnvironment=XDG_CURRENT_DESKTOP=niri`.

- [ ] **Step 6: Run the invariance check**

Expected: every pair identical.

- [ ] **Step 7: Format, check, commit**

Run: `nix fmt` then `nix flake check`
Commit: `homeModules.theonecfg.programs: add niri and noctalia, enable on ilmenite`

______________________________________________________________________

### Task 7: Switch over and test on the hardware

Owner-driven. Any failed test: stop and ask before changing anything.

**Files:**

- Modify: `docs/plans/active/ilmenite-niri-desktop.md` ("Hardware
  verification" section: per test, the time, the result, the journal lines)

- Modify: `homeConfigurations/ilmenite/djacu/default.nix` (Samsung output
  name, only if test 2 shows a different string)

- [ ] **Step 1: Preconditions, confirmed by the owner**

(a) The owner knows how to get back: in the boot menu (shown for 5 s)
select the generation recorded in Task 1; that choice lasts one boot;
`sudo nixos-rebuild boot --rollback` run from it makes it the default. The
home configuration needs no rollback: Noctalia only starts under niri.
(b) A second way in exists: SSH from another machine works, or the owner
will log in on a text console (Ctrl+Alt+F3) before the first lock.
(c) The owner knows the two recoveries: a blank screen instead of the
greeter means Ctrl+Alt+F2, log in, `sudo systemctl restart greetd`; a
locked screen with no prompt (solid red) means Super+Alt+L, or
`loginctl lock-session` from the second way in.

- [ ] **Step 2: Write the hand-over note before the reboot**

The reboot ends the builder's session. Before it, add a "Resume here" line
at the top of the design doc's "Hardware verification" section naming the
next test, commit it, and tell the owner to reopen the session from the
worktree in kitty after logging in to niri. Repeat this before any test
that logs out or reboots (tests 3, 17, 18).

- [ ] **Step 3: Owner applies the system, then the home config, then reboots**

From the worktree: `sudo nixos-rebuild boot --flake .#ilmenite`, then
`home-manager switch --flake .#ilmenite-djacu`, then reboot at once.
`boot`, not `switch`: replacing the display manager under a running Plasma
session ends it uncleanly. If the owner uses different commands for these,
use theirs. After the home switch and before the reboot, the builder runs
`systemctl --user is-active noctalia` and expects `inactive`: the unit must
not start under Plasma.

- [ ] **Step 4: Run the tests in order**

The builder gives one test at a time, waits for the owner's report, then
reads the journal and states what it shows. Tests marked AC or BAT say what
the charger state must be at the start. A test that involves the lid must
start at least 30 s after the last boot or resume, because logind ignores
the lid for that long; the builder checks the journal for the time of the
last resume before giving such a test. Tests 2 (Samsung name), 14 and 15
need the work dock or any external screen and may be done on another day.

| #   | Start | Test (owner)                                                                                                                                                   | Pass                                                                                                                     |
| --- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 1   | any   | Boot. At the greeter type the password and press Enter.                                                                                                        | logs in at once, with no fingerprint wait, to niri with Noctalia's bar                                                   |
| 2   | AC    | In kitty: `niri msg outputs`, `systemctl --user status noctalia`, `powerprofilesctl get`                                                                       | outputs listed; service active; `performance`                                                                            |
| 3   | any   | Log out from Noctalia's session menu (`noctalia msg panel-toggle session`), log in with the password                                                           | password login works; the builder then takes the login time from the journal as in Task 1                                |
| 4   | any   | Press each: volume up, down, mute, mic mute, brightness up and down, play. Mod+T, Mod+D.                                                                       | each acts and shows Noctalia's display; kitty and the launcher open                                                      |
| 5   | any   | With the second way in ready: Super+Alt+L. While locked press volume up. Unlock by password. Lock again, unlock by finger.                                     | volume changes while locked; both unlocks work                                                                           |
| 6   | any   | Lock. From the second way in: `systemctl --user restart noctalia`. Report what the screen shows. If there is no prompt, press Super+Alt+L. Unlock.             | record whether it stayed locked; a prompt comes back and unlock works. If the restart unlocked the session, stop and ask |
| 7   | any   | `pkexec true` in kitty; `notify-send test hello`; in Firefox, File, Open File; start Slack                                                                     | Noctalia's polkit prompt; a notification; a file chooser; Slack's window appears                                         |
| 8   | AC    | Unplug, wait 5 s, `powerprofilesctl get`. Plug in, wait 5 s, again. Do this three times.                                                                       | `balanced` then `performance`, all three times                                                                           |
| 9   | AC    | Lid open, hands off for 11 min (screen off, then locked). Still hands off, unplug. Wait 1 min.                                                                 | asleep within about 40 s of the unplug; journal shows a suspend entry                                                    |
| 10  | BAT   | Unlocked, close the lid, wait 20 s, open, touch the reader                                                                                                     | journal shows `PM: suspend entry` and exit between close and unlock; unlocks by finger. Blocker                          |
| 11  | BAT   | Lock, close the lid within 3 s, wait 20 s, open, touch the reader                                                                                              | same journal evidence; unlocks by finger. Blocker                                                                        |
| 12  | BAT   | Press the power button briefly. While it sleeps, plug in the charger. Wake it, `powerprofilesctl get`. Unplug. Then Noctalia's session menu, Suspend. Wake it. | both sleeps: journal names `suspend-then-hibernate`; locked on wake; profile is `performance` after the first wake       |
| 13  | BAT   | Lid open, hands off 12 min                                                                                                                                     | screen off at 5 min, asleep after 10; locked on wake                                                                     |
| 14  | BAT   | External screen attached, `noctalia msg caffeine-enable`, a still window on it, hands off 12 min. Then `caffeine-disable`.                                     | both screens stay on, no lock, no sleep. Also record that the screen extended when plugged in, and try `wl-mirror eDP-1` |
| 15  | AC    | Docked with the lid closed, working on the external screen: unplug the dock                                                                                    | asleep within about a minute; locked on wake                                                                             |
| 16  | AC    | No external screen: close the lid, wait 40 s, unplug the charger, wait 1 min, open                                                                             | journal shows no suspend before the unplug and a suspend after it                                                        |
| 17  | BAT   | Close the lid, wait 35 min, open                                                                                                                               | powered off; boots, asks for the disk passphrase once, returns to the locked session; finger unlocks. Blocker            |
| 18  | BAT   | Shut down while on AC. Unplug. Boot, log in, `powerprofilesctl get`                                                                                            | `balanced`                                                                                                               |
| 19  | AC    | Lid open, hands off 12 min                                                                                                                                     | screen off and locked, not asleep                                                                                        |

Journal command after each test, with the start time filled in:

```sh
journalctl -b 0 --no-pager -o short-precise --since "HH:MM:SS" | grep -E "noctalia|niri\[|fprintd|greetd|systemd-logind|systemd-sleep|suspend-then-hibernate|PM: (suspend|hibernation)|Lid (opened|closed)|Sleep Actions|power-profile-ac|power-profiles-daemon"
```

A resume from hibernate continues the same boot, so `-b 0` covers test 17
too. For tests 10 to 13 and 17, "which kind of sleep" is read from the
logind line "suspend-then-hibernate requested" or systemd-sleep's "System
returned from sleep operation 'suspend-then-hibernate'"; a bare
"Performing sleep operation 'suspend'" appears in both kinds and proves
nothing. For tests 10, 11 and 17 also quote Noctalia's fingerprint lines
("claimed fingerprint device", "could not ...", "no fprintd device
available").

- [ ] **Step 5: Record and commit**

Write each result into the design doc as it comes in. If the Samsung output
name differed, correct it and have the owner run `home-manager switch`
again.
Commit: `docs: record ilmenite niri hardware verification` (and the output
name fix as its own commit if there was one).

______________________________________________________________________

### Task 8: Tuning with the owner

Interactive. Nothing here is decided in advance beyond the starting points
in the spec.

**Files:**

- Modify: `homeModules/programs/niri/module.nix`,
  `homeModules/programs/noctalia/module.nix`,
  `homeConfigurations/ilmenite/djacu/default.nix`

- [ ] **Step 1: Make the niri config editable in place**

The owner runs

```sh
cp --remove-destination "$(readlink -f ~/.config/niri/config.kdl)" ~/.config/niri/config.kdl
chmod u+w ~/.config/niri/config.kdl
```

so the niri config is a plain writable file that reloads on save. While
that copy exists, `home-manager switch` refuses to run ("would be
clobbered"); that is expected until Step 3. Noctalia needs nothing: its
settings window writes `~/.local/state/noctalia/settings.toml` on top of
the managed config.

- [ ] **Step 2: Tune**

Go through, one at a time, with the owner in the session:

- a key or bar button for keep-awake (`noctalia msg caffeine-toggle`);
  required by the spec;

- keys for the session menu, clipboard history and `wl-mirror` mirroring;

- column widths on each screen as used;

- cursor theme; Noctalia's theme, bar and wallpaper; idle timings;

- optionally `noctalia msg greeter-sync`, to give the greeter the shell's
  wallpaper and colours.

- the GnuPG prompt (owner's request, 2026-11-23): switch from `pinentry-qt`
  to `pinentry-gnome3`, set from the niri home module so the Plasma hosts
  keep `pinentry-qt`; the shared gpg module sets the package plainly, so the
  override needs a priority. Test with one signed commit. Done 2026-11-26.
  Known and accepted by the owner: the GNOME dialog sizes itself to its
  title, which pinentry builds from the caller's full command line, so the
  real prompt opens over half the screen wide. niri cannot shrink it, and
  the owner declined a wrapper that would strip the caller from the title.

- Qt apps look plain without Plasma's theme. Noctalia's templates can
  generate matching GTK and Qt colours; try them.

- a file manager and an image viewer (owner's question, 2026-11-23).
  Nautilus is in the system only for file dialogs and is not in the
  launcher; `imv` and `mpv` are the only image viewers installed. Done
  2026-11-26: Luciole (the Noctalia project's file manager, packaged in
  this repo) and Loupe, each the default for its file types.

- go through the Noctalia project's plugins (owner's request,
  2026-11-26): 15 official and about 370 community ones, listed at
  noctalia.dev/plugins.

- Noctalia's storage-key warning at start-up (see the design doc).

- [ ] **Step 3: Carry the result into Nix and drop the live copies**

Port the changed KDL into the niri module (or the host config for
per-monitor settings). Print Noctalia's choices with
`noctalia config export` and port them into `settings`. Build the home
config and confirm every ported Noctalia setting appears in
`noctalia config export full` as in Task 6 Step 5. Then the owner deletes
`~/.config/niri/config.kdl` and `~/.local/state/noctalia/settings.toml` and
runs `home-manager switch`. Confirm the session looks and behaves the same.

- [ ] **Step 4: Build, format, check, commit**

Commit per topic, for example
`homeModules.theonecfg.programs.niri: bind session menu, clipboard and mirroring`.

- [ ] **Step 5: Home desk, when ilmenite is next docked there**

`niri msg outputs`, then add the two 4K monitors as `output` blocks in the
host config: landscape with width steps 1/3, 1/2, 2/3 and full; portrait
rotated, with full width only. Scale and position are the owner's call at
the desk. Then mark the design doc completed and move both plan files to
`docs/plans/completed/`.
