# ilmenite hibernation verification

**Status:** In progress
**Date:** 2026-10-04
**Owner:** djacu
**Context:** Tasks 6 and 7 of `docs/plans/active/ilmenite-hibernation-implementation.md`; design in `docs/plans/active/ilmenite-hibernation.md`

## Install log

- Staged fingerprint: SHA256:kkTuWyYgjKxk+dXIuRF+DUjwTuSz2FgLzWlXY8cEYkk (ED25519); machine-id: 74131ab09e7c46aca49811afc213d2cd. Passphrase file checked: last byte `\n`.
- Host-id pre-seed: both `od` lines `4d a7 66 11`.
- Install: 2026-10-04, nixos-anywhere from argentite; prompts at first boot: 1 (`Please enter passphrase for disk disk-disk1-swap (cryptswap)`), prompt
  named cryptswap; anything odd in the disko or nixos-install
  output: none reported.
- Post-install checks: all passed (read-only over SSH at 10.0.10.85): `resume=/dev/mapper/cryptswap`, no `nohibernate`; swap `/dev/dm-0` 68G = `/dev/mapper/cryptswap`, `Options=defaults,discard=once`, active; `encryption off`; hostid `1166a74d`; machine-id and fingerprint as staged; no failed units; `zpool status` ONLINE on `dm-uuid-CRYPT-LUKS2-...-cryptzroot`; sleep.conf and powerdevilrc as evaluated. logind `CanSuspendThenHibernate` answered `challenge` over SSH, which is polkit for a non-local caller; Plasma treats `challenge` like `yes`.
- `BAT1/alarm` at first boot: `480000`, greater than zero, so systemd takes the firmware alarm path; test 3 decides whether Task 7a is needed. Greater than zero means systemd uses
  the firmware alarm path in suspend-then-hibernate.

## Tests

The owner runs the (ilmenite) commands in fish on the laptop; the executor
runs the (argentite) commands in bash over SSH, read-only. systemd-sleep's
path decisions are debug-level messages, so each session that includes
tests 3, 4, or 5 starts with the session setup below and ends with its
removal. The drop-ins live in `/run`: a resume keeps them, a cold boot
drops them, so repeat the setup after any reboot.

Session setup (ilmenite):

```fish
sudo mkdir -p /run/systemd/system/systemd-suspend-then-hibernate.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' | sudo tee /run/systemd/system/systemd-suspend-then-hibernate.service.d/debug.conf
sudo systemctl daemon-reload
```

Session teardown (ilmenite):

```fish
sudo rm -rf /run/systemd/system/systemd-suspend-then-hibernate.service.d /run/systemd/sleep.conf.d
sudo systemctl daemon-reload
```

### 1. Cold boot ordering

(ilmenite) Reboot, count prompts. Then:

```fish
journalctl -b -o short-monotonic -u systemd-cryptsetup@cryptswap.service -u systemd-cryptsetup@cryptzroot.service -u systemd-hibernate-resume.service -u zfs-import-zroot.service -u rollback-root.service --no-pager
journalctl -b -p warning --no-pager | grep -i 'ordering cycle'
```

Pass: one prompt; in the first listing `systemd-cryptsetup@cryptswap.service`
finishes before `systemd-hibernate-resume.service` starts (the resume unit
binds to the swap mapper, not the pool one, so `cryptzroot` may finish
later); the resume unit and `systemd-cryptsetup@cryptzroot.service` both
finish before `zfs-import-zroot.service` starts; the import finishes before
`rollback-root.service` starts. The second command prints nothing. (PID 1 logs
units by description, so the unit filters are what make the first command
show them.)

### 2. Hibernate and resume, cold ARC and warm ARC

(ilmenite) `/tmp` lives on the root dataset, which is rolled back on every
cold boot, so a marker there survives a resume and nothing else:

```fish
date -u > /tmp/hibtest-marker; cat /tmp/hibtest-marker; cat /proc/uptime
systemctl hibernate
```

Power on. One prompt. Then:

```fish
cat /tmp/hibtest-marker; cat /proc/uptime
sudo dmesg | grep -i -E 'ACPI (BIOS )?Error|_WAK|BERT|Hardware Error' | head
sudo dmesg | grep -i -E 'sleep state S4|failed to restore|dpm_run_callback|spd5118' | tail -n 8
```

Pass: marker from before the hibernate, uptime continued, no ACPI errors,
S4 entry and wake lines present. Note whether `spd5118` still returns `-6`.

Warm ARC: the ARC cap at this pin is RAM minus 1 GiB, about 63 GiB. Write a
random file of 50 GB, read it twice, confirm the ARC holds most of it, then
hibernate again the same way. This pushes saveable memory well past the
kernel's half-of-RAM image limit, so the ARC shrinker must give memory back.

```fish
dd if=/dev/urandom of=/home/djacu/arcfill bs=1M count=50000 status=progress
cat /home/djacu/arcfill > /dev/null; cat /home/djacu/arcfill > /dev/null
grep -E '^(size|c_max) ' /proc/spl/kstat/zfs/arcstats
date -u > /tmp/hibtest-marker; systemctl hibernate
```

After the resume: marker present; `sudo dmesg | grep -i -E 'hibernation|Image' | tail -n 12` shows the image page count and no "Image allocation" or "Not
enough" error. Then `rm /home/djacu/arcfill`.

### 3. suspend-then-hibernate with a short delay

(ilmenite) Session setup first. Then a runtime-only sleep override, no
rebuild:

```fish
sudo mkdir -p /run/systemd/sleep.conf.d
printf '[Sleep]\nHibernateDelaySec=2min\nSuspendEstimationSec=2min\nHibernateOnACPower=yes\n' | sudo tee /run/systemd/sleep.conf.d/test.conf
date -u > /tmp/hibtest-marker; systemctl suspend-then-hibernate
```

Expected: suspend; after about two minutes the machine wakes by itself and
powers off (hibernated). Power on, one prompt, session back. Then:

```fish
cat /tmp/hibtest-marker
journalctl -b -u systemd-suspend-then-hibernate.service --no-pager | grep -i -E 'alarm|APM Timer|wakeup|Timer fired|timeout|estimat|hibernat|suspend' | head -n 40
sudo rm /run/systemd/sleep.conf.d/test.conf
```

Pass: marker present; the debug log shows which path systemd took
(firmware alarm or timer) and, on the alarm path, "Woken by APM Timer"
rather than a silent exit after the wake. If the alarm path misjudged the
wake, which shows as the machine coming back awake after two minutes with
no hibernate and Plasma re-suspending it about ten seconds later, record
it and run Task 7a before test 4.

### 4. Lid on battery

(ilmenite, session setup active) Unplug.
`cat /sys/class/power_supply/BAT1/charge_now`, close the lid for ten
minutes, open it. Pass: `journalctl -b -u systemd-suspend-then-hibernate.service --no-pager` shows one suspend entry
and no hibernate; `charge_now` dropped by about 0.1 %.

Overnight: `cat /sys/class/power_supply/BAT1/charge_now; date`, close the
lid unplugged, leave it. In the morning the machine is off. Power on, one
prompt, session back; `charge_now` again. Pass: the debug log shows the
hibernate about 3 h after the lid close, and the total drop is about 1.5 %
plus the hibernate.

### 5. Lid on AC, then unplug

(ilmenite, session setup active) Plugged in through the hub, no external
monitor. Close the lid for more than three hours, open it:

```fish
journalctl -b -u systemd-suspend-then-hibernate.service --since -5h --no-pager | grep -i -E 'suspend|wake|Timer fired|AC power|hibernat' | head -n 40
```

Pass: a wake about every three hours, each logged as the timer firing on
AC and followed by a new suspend, no hibernate. Then close the lid again,
unplug the hub after ten minutes, and leave it. Pass: within three hours
the machine is off; power on, one prompt, session back. Run the session
teardown afterwards.

### 6. logind and Plasma agree

(ilmenite)

```fish
busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspendThenHibernate
cat /sys/class/power_supply/BAT1/alarm
```

Pass: `s "yes"` from the Plasma session (`challenge` when asked over SSH, which Plasma also accepts). System Settings, Power Management, "When sleeping, enter"
shows "Standby, then hibernate" for both the AC and the battery tabs, and
the low-battery tab's lid action shows Hibernate. Record the alarm value.

### 7. KVM, lid closed

(ilmenite on the hub with the KVM's monitor) Close the lid: nothing happens
(clamshell). Switch the KVM away and wait a minute. Record whether the
laptop suspended (the monitor disappeared) or kept running (EDID emulation).
If it suspended, press a key on the hub keyboard: record whether that woke
it. Then, with the lid still closed, `systemctl hibernate` from the laptop
over SSH, power on, and record where the passphrase prompt appeared,
internal panel or external monitor.

### 8. Discard on cold boot

(ilmenite) After any cold boot:

```fish
systemctl show -p Options -p ActiveState dev-mapper-cryptswap.swap
set dm (basename (readlink -f /dev/mapper/cryptswap)); cat /sys/block/$dm/queue/discard_granularity
```

Pass: `Options=defaults,discard=once` and `ActiveState=active` (Review Focus 7);
the granularity is greater than `0`, so the discard reaches the drive
through dm-crypt.

## Results

| Test | Date       | Result | Notes                                                                                                                                                                                                                                                                                                                        |
| ---- | ---------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | 2026-10-04 | pass   | First boot after the reinstall: one prompt. Journal (monotonic): cryptswap finished 17.16 s, resume unit ran 17.16 to 17.17 s, cryptzroot finished 19.04 s from the cached passphrase, import 19.04 to 19.26 s, rollback 19.26 to 19.32 s. No ordering cycle.                                                                |
| 2a   | 2026-10-05 | pass   | Cold ARC, `systemctl hibernate` from Plasma: marker kept, uptime continued, no ACPI errors, S4 entry and wake logged. Drivers: `spd5118` `-6` at thaw and restore (cosmetic); `btintel_pcie` `pci_pm_poweroff returns -16` during the power-off after the image write; Bluetooth function after resume checked by the owner. |
|      |            |        |                                                                                                                                                                                                                                                                                                                              |

## Decision

\<Pass or fail against the spec's exit criteria, and anything changed as a result.>
