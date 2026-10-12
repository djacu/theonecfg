{
  lib,
  coreutils,
  curl,
  drduh-yubikey-guide,
  gawk,
  gnupg,
  testers,
  theonecfgModulesPath,
  writeShellApplication,
}:
let

  # Rehearses the runbook's renewal against a throwaway key. The renewal line
  # below must stay identical to docs/runbooks/renew-yubikey-gpg-subkeys.md.
  rehearsal = writeShellApplication {
    name = "yubikey-live-rehearsal";
    runtimeInputs = [
      coreutils
      gawk
      gnupg
    ];
    text = ''
      export GNUPGHOME
      GNUPGHOME=$(mktemp -d)
      P=throwaway
      IDENTITY='Throwaway <throwaway@example.invalid>'

      gpg --batch --passphrase "$P" --quick-gen-key "$IDENTITY" rsa2048 cert never
      KEY_FP=$(gpg -k --with-colons "$IDENTITY" | awk -F: '/^fpr:/ { print $10; exit }')

      # --batch --passphrase only takes effect together with loopback pinentry
      # (gpg(1), --passphrase: "Since Version 2.1 the --pinentry-mode also
      # needs to be set to loopback").
      for usage in sign encrypt auth; do
        gpg --batch --pinentry-mode loopback --passphrase "$P" \
          --quick-add-key "$KEY_FP" rsa2048 "$usage" 1d
      done

      # In --with-colons output the first fpr line belongs to the primary key;
      # the following ones are the subkeys in creation order.
      mapfile -t SUB_FPS < <(gpg -K --with-colons | awk -F: '$1 == "fpr" { if (++n > 1) print $10 }')
      SUB_FP_SIGN=''${SUB_FPS[0]}
      SUB_FP_ENCRYPT=''${SUB_FPS[1]}
      SUB_FP_AUTH=''${SUB_FPS[2]}
      KEY_EXPIRATION=$(date -d '+1 year' +%F)
      CERTIFY_PASS=$P

      # Field 7 of sec/ssb (and pub/sub) lines is the expiry in epoch seconds,
      # empty when the key never expires. The primary must stay empty: with an
      # empty subkey list --quick-set-expire silently falls back to its
      # two-argument form and sets the certify key's expiry instead.
      check_expiry() {
        awk -F: -v want="$1" '
          $1 ~ /^(sec|pub)$/ && $7 != "" { print "certify key gained an expiry"; exit 1 }
          $1 ~ /^(ssb|sub)$/ {
            n++
            if ($7 < want - 86400 || $7 > want + 86400) { print "subkey expiry " $7 " is not near " want; exit 1 }
          }
          END { if (n != 3) { print "expected 3 subkeys, saw " n; exit 1 } }'
      }
      want=$(date -d "$KEY_EXPIRATION" +%s)

      # Renewal line, verbatim from the runbook.
      printf '%s' "$CERTIFY_PASS" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
          --quick-set-expire "$KEY_FP" "$KEY_EXPIRATION" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH"
      gpg -K --with-colons | check_expiry "$want"

      # gpg keeps the newest binding signature by creation time, so a renewal
      # made with a clock earlier than the existing signatures changes nothing
      # and reports nothing. The runbook relies on a gpg -K check to catch
      # that; prove the check works by renewing to a different date with a
      # clock set to 2020 and asserting the expiry did not move. gpg may or
      # may not exit non-zero on the back-dated run; either way the expiry
      # must be unchanged.
      printf '%s' "$CERTIFY_PASS" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 --faked-system-time 20200101T000000 \
          --quick-set-expire "$KEY_FP" "$(date -d '+2 years' +%F)" "$SUB_FP_SIGN" "$SUB_FP_ENCRYPT" "$SUB_FP_AUTH" || true
      gpg -K --with-colons | check_expiry "$want"

      # keyid-format 0xlong can only come from /etc/gnupg/gpg.conf; this
      # GNUPGHOME has no gpg.conf of its own. grep -c rather than -q: -q
      # closes the pipe on the first match and the writer fails under
      # pipefail.
      gpg -k | grep -c 'rsa2048/0x' > /dev/null
      # cert-digest-algo SHA512 shows as digest algo 10 on the self-signatures.
      gpg --export "$KEY_FP" | gpg --list-packets | grep -c 'digest algo 10' > /dev/null

      # The armored export is what the daily machines import; it must carry
      # the renewal into a fresh keyring.
      asc=$(mktemp)
      gpg --armor --export "$KEY_FP" > "$asc"
      other=$(mktemp -d)
      GNUPGHOME=$other gpg --import "$asc"
      GNUPGHOME=$other gpg -k --with-colons | check_expiry "$want"
    '';
  };

in
testers.runNixOSTest {
  name = "yubikey-live";

  nodes.machine =
    { lib, ... }:
    {
      # The flake's default NixOS module sets nixpkgs.overlays, which the test
      # framework makes read-only, and its user modules need the theonecfg
      # registry. The two profiles below need neither, so they are imported
      # by path and the node keeps the framework's pkgs, which already carry
      # this repo's overlays.
      imports = [
        "${theonecfgModulesPath}/profiles/common/module.nix"
        "${theonecfgModulesPath}/profiles/yubikey-live/module.nix"
      ];

      networking.hostName = "uraninite";
      theonecfg.profiles.yubikey-live.enable = true;

      # The ISO logs in djacu, created by the host file; the test only needs
      # some unprivileged user to run the rehearsal as.
      users.users.tester.isNormalUser = true;

      # vlans = [] removes the per-vlan NICs only. qemu-vm adds a SLiRP user
      # NIC to every VM unconditionally, and with no network flag at all QEMU
      # falls back to its own default user-mode NIC; "-nic none" is the one
      # way to get a VM with only lo, which the air-gap check below needs.
      virtualisation.vlans = [ ];
      virtualisation.qemu.networkingOptions = lib.mkForce [ "-nic none" ];

      environment.systemPackages = [ curl ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Air gap: the loopback interface is the only one allowed to exist.
    links = [line.split()[0] for line in machine.succeed("ip -br link").splitlines() if line.strip()]
    assert links == ["lo"], f"unexpected interfaces: {links}"
    machine.fail("systemctl is-active sshd.service")
    machine.fail("systemctl is-active NetworkManager.service")
    # pcscd is socket-activated; the service only starts on the first client.
    machine.succeed("systemctl is-active pcscd.socket")
    machine.wait_for_unit("nginx.service")

    # Both configs must parse. A bare flag written into gpg-agent.conf as
    # "name true" would stop the agent from starting at all.
    machine.succeed("runuser -u tester -- env HOME=/home/tester gpgconf --check-options gpg")
    machine.succeed("runuser -u tester -- env HOME=/home/tester gpgconf --check-options gpg-agent")
    machine.fail("grep -q enable-ssh-support /etc/gnupg/gpg-agent.conf")

    machine.succeed("test -r ${drduh-yubikey-guide}/share/drduh-yubikey-guide/README.md")
    machine.succeed("command -v view-yubikey-guide")
    # grep -c reads to the end; grep -q would close the pipe on the first
    # match and curl would fail with a write error under pipefail.
    machine.succeed("curl -sf http://127.0.0.1:8080/index.html | grep -c -i diceware")

    machine.succeed("runuser -u tester -- env HOME=/home/tester ${lib.getExe rehearsal}")
  '';
}
