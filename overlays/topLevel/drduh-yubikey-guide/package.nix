{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation {
  pname = "drduh-yubikey-guide";
  version = "0-unstable-2026-10-04";

  src = fetchFromGitHub {
    owner = "drduh";
    repo = "YubiKey-Guide";
    rev = "a4f662fb4d8bac8d424a7bcfef8dea2eb250eec7";
    hash = "sha256-zWYmVW+uwW8NcFS4LDipONyLXMui9kfEIfgHcH0CQK8=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/drduh-yubikey-guide
    cp -r README.md config scripts templates $out/share/drduh-yubikey-guide/
    cp nix/diceware-vt.patch $out/share/drduh-yubikey-guide/
    runHook postInstall
  '';

  meta = {
    description = "Guide to using YubiKey for GnuPG and SSH, with its gpg configuration files";
    homepage = "https://github.com/drduh/YubiKey-Guide";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
