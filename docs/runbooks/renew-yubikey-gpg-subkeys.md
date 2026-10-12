# Renew the YubiKey GPG subkeys

Push the expiry of the three subkeys on the YubiKey forward using the
offline certify key, on an air-gapped laptop booted from the `uraninite`
live ISO. Nothing is written to the YubiKey; subkey expiry lives in
self-signatures on the public key.

The VM test `theonecfgTests.yubikey-live` (`hydra-jobs/vm-tests.nix`) runs
the renewal line below against a throwaway key. Keep the two identical.

## Prerequisites

- A build host with this repo (ilmenite) and three USB sticks: one for the
  ISO (4 GB or more), the backup stick (a single LUKS partition holding a
  `GNUPGHOME` directory: `gnupg` from the original provisioning, and a
  `<date>-renewed` copy after each renewal), and an empty transfer stick.
- The certify key passphrase.
- A second laptop that boots x86_64 UEFI media with Secure Boot turned
  off.
- The current key, for reference:
  - certify `0x8C9CFEF8EE37DA95`, fingerprint
    `6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95`, never expires
  - sign `0xA574F8E664B73493`, `D41E63419DF2EBB72527F45AA574F8E664B73493`
  - encrypt `0xE1B97FBD677703EC`, `73FFB33FADE8CE280ACBAA21E1B97FBD677703EC`
  - auth `0xF6B7FFB11D29B9E3`, `FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3`

Parameters you set: the new expiry date, the three USB device names, and
the name of the newest backup directory.

## Procedure

### 1. Build and flash the ISO (ilmenite, fish)

```fish
cd ~/dev/djacu/theonecfg
nix build .#nixosConfigurations.uraninite.config.system.build.isoImage
lsblk
```

Confirm the ISO stick's device, then, with `sdX` replaced:

```fish
sudo dd if=result/iso/uraninite.iso of=/dev/sdX bs=4M status=progress oflag=sync
sudo cmp -n (stat -c %s result/iso/uraninite.iso) result/iso/uraninite.iso /dev/sdX; and echo flash verified
```

The ISO file is `uraninite.iso` exactly, no version suffix.

### 2. Prepare the transfer stick (ilmenite, fish)

Plug in the empty transfer stick, `lsblk`, confirm its device `sdY`, then:

```fish
sudo mkfs.vfat -n GPGPUBLIC /dev/sdY
```

Whole device, no partition table. It will carry only the public key.

### 3. Boot the ceremony laptop

Boot from the ISO stick with Secure Boot off. Plasma logs in as `djacu`
without a prompt. Open a terminal and start `bash`; the login shell is fish
and the commands below are bash.

```bash
bash
ip -br link
ip -br addr
systemctl is-active pcscd.socket
date
```

`ip -br link` lists `lo` and the laptop's own network hardware; every
interface other than `lo` must show `DOWN`. `ip -br addr` must show
addresses on `lo` only. The configuration never brings an interface up;
the hardware existing is expected. The YubiKey is not needed and can stay
at home. If `date` is wrong, set it before going on:

```bash
sudo date -s 'YYYY-MM-DD HH:MM'
```

A wrong clock has two faces, and neither renews anything. A clock after
the key's creation (2025-10-19) but before the newest signature (the date
in the committed `.asc` file name) is refused with
`make_keysig_packet failed: Time conflict`. A clock before 2025-10-19 is
accepted with "created N days in the future" warnings, but gpg keeps the
newest signature by creation time, so the back-dated one loses silently.
Step 7's `gpg -K` is the check that catches both.

### 4. Mount the backup and transfer sticks

Plug in the backup stick, find its partition with `lsblk`, then with `sdX1`
replaced:

```bash
sudo cryptsetup luksOpen /dev/sdX1 gnupg-secrets
sudo mkdir -p /mnt/encrypted-storage /mnt/public
sudo mount /dev/mapper/gnupg-secrets /mnt/encrypted-storage
ls /mnt/encrypted-storage
```

Plug in the transfer stick:

```bash
sudo mount /dev/disk/by-label/GPGPUBLIC /mnt/public
```

### 5. Copy the certify key into a temporary GNUPGHOME

Pick the directory from the `ls` above that holds the keyring and put its
name in `BACKUP`: `gnupg` on the first renewal, the newest
`<date>-renewed` afterwards:

```bash
BACKUP=gnupg
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
sudo cp -av "/mnt/encrypted-storage/$BACKUP/." "$GNUPGHOME"/
sudo chown -R djacu "$GNUPGHOME"
rm -f "$GNUPGHOME"/gpg-agent.conf
gpg -K
```

The `rm` drops any agent config saved with the backup so the live system's
own applies. `gpg -K` must show `sec` (not `sec#`) for `0x8C9CFEF8EE37DA95`
and the three subkeys.

### 6. Set the variables

```bash
export KEY_FP=6EC37842237BED45CBA6D3A58C9CFEF8EE37DA95
export SUB_FP_SIGN=D41E63419DF2EBB72527F45AA574F8E664B73493
export SUB_FP_ENCRYPT=73FFB33FADE8CE280ACBAA21E1B97FBD677703EC
export SUB_FP_AUTH=FAC51E7D0EE7290A2D7A120BF6B7FFB11D29B9E3
export KEY_EXPIRATION=2027-10-19
read -rs CERTIFY_PASS; export CERTIFY_PASS
```

The fingerprints are written out on purpose. The guide derives them with an
`awk` pipeline; if that pipeline yields nothing, `--quick-set-expire` falls
back to its two-argument form and sets an expiry on the certify key, with
exit 0 and no warning.

### 7. Renew

```bash
printf '%s' "$CERTIFY_PASS" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
gpg -K
```

Stop unless all three subkeys show `expires:` with the date you put in
`KEY_EXPIRATION` and the certify key still shows no expiry.

### 8. Export and update the backup

```bash
gpg --armor --export "$KEY_FP" | sudo tee "/mnt/public/8C9CFEF8EE37DA95-$(date +%F).asc" > /dev/null
sudo cp -av "$GNUPGHOME" "/mnt/encrypted-storage/$(date +%Y.%m.%d)-renewed"
```

The export is named by its export date, as drduh's guide names it, so the
file says how fresh its signatures are. It contains public material only.
The copy gives next year's
renewal a starting point with the current signatures; the original backup
directory is never modified.

### 9. Close down

```bash
unset CERTIFY_PASS
sudo umount /mnt/public /mnt/encrypted-storage
sudo cryptsetup luksClose gnupg-secrets
```

Power off. The temporary directory is on tmpfs and dies with it. The backup
stick goes back to storage; only the transfer stick travels.

### 10. Import on ilmenite (fish)

Plug in the transfer stick:

```fish
sudo mkdir -p /mnt/public
sudo mount /dev/disk/by-label/GPGPUBLIC /mnt/public
gpg --import /mnt/public/8C9CFEF8EE37DA95-*.asc
gpg -K
```

The three card-backed subkeys show the new expiry. No agent restart is
needed. If `gpg -K` lists no subkeys at all, gpg-agent has lost its card
stubs; insert the YubiKey and run `gpg --card-status`, then look again.

### 11. Update the repo (ilmenite, fish)

Set `new` to the exact file name section 8 wrote. The ISO clock is UTC, so
the date in the name can be the day after the local ceremony date. Do not
glob it: the transfer stick may carry an older export too, and a
two-element `new` would write both names into the module.

```fish
cd ~/dev/djacu/theonecfg
git switch -c djacu/gpg-renewal-(date +%Y)
set new 8C9CFEF8EE37DA95-YYYY-MM-DD.asc
test -f /mnt/public/$new; or echo "no such file on the transfer stick"
git rm home-modules/users/djacu/programs/gpg/8C9CFEF8EE37DA95-*.asc
cp /mnt/public/$new home-modules/users/djacu/programs/gpg/$new
sed -i "s|source = ./8C9CFEF8EE37DA95-.*\\.asc;|source = ./$new;|" home-modules/users/djacu/programs/gpg/module.nix
sudo umount /mnt/public
git add home-modules/users/djacu/programs/gpg
git diff --cached --stat
home-manager switch --flake .#ilmenite-djacu
gpg -k 0x8C9CFEF8EE37DA95
git commit
```

`git diff --cached --stat` must show one file removed, one added, and
`module.nix` changed by one line. Commit subject:
`homeModules.users.djacu.programs.gpg: renew subkeys to <KEY_EXPIRATION>`.
Open the PR and merge it.

### 12. The other hosts

On argentite, cassiterite, malachite and scheelite, after pulling `main`:

```fish
home-manager switch --flake .#(hostname)-djacu
gpg -k 0x8C9CFEF8EE37DA95
```

Each shows the new expiry on the subkeys. home-manager re-imports the
committed public key on every switch.

### 13. GitHub

Settings, SSH and GPG keys: remove the GPG key `8C9CFEF8EE37DA95` and add
the contents of the new `.asc`. GitHub keeps the Verified status of commits
from the record made when they were first verified, so older commits stay
Verified.

## Post-ceremony checks

```fish
cd ~/dev/djacu/theonecfg
git commit --allow-empty -m "test: signed commit after renewal"
git log -1 --show-signature
```

`Good signature`. Push a branch and check the Verified badge on that commit
and on a commit from before the renewal. Delete the test branch afterwards.

## Known gotchas

- The login shell on the ISO is fish; the ceremony commands are bash. Run
  `bash` first.
- `--quick-set-expire` needs the certify key's fingerprint as its first
  argument; a key id is rejected.
- `--batch --passphrase-fd 0` only works with `--pinentry-mode loopback`.
- The backup `GNUPGHOME` may contain a `gpg-agent.conf` from the machine
  that created it; the runbook removes it after the copy.
- The ISO has no NTP. Check the clock.
- Next year, pick the `-renewed` directory as `BACKUP`; the 2025 directory
  carries the old signatures.
- `require-secmem` in gpg.conf makes gpg refuse to run if memory locking
  fails. If it does: `ulimit -l unlimited` in the ceremony shell.
- A commit failing with `Unusable secret key` on a daily machine is usually
  missing card stubs, not expiry: `gpg --card-status` with the key
  inserted.

## Recovery

- A failed `--quick-set-expire` changes nothing; fix the cause and re-run
  it.
- A wrong or damaged `.asc` on the online side: re-export from the backup
  stick; the ceremony can be repeated, it only adds signatures.
- An incomplete `-renewed` copy: delete that directory on the LUKS volume
  and copy again. Never touch the original dated directory.
- If `gpg -K` on the ceremony laptop shows `sec#`, the backup directory
  does not hold the secret certify key; try another directory before
  anything else.
