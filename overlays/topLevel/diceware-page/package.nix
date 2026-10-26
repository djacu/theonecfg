{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  drduh-yubikey-guide,
}:
stdenvNoCC.mkDerivation {
  pname = "diceware-page";
  version = "0-unstable-2022-10-28";

  src = fetchFromGitHub {
    owner = "grempe";
    repo = "diceware";
    rev = "9ef886a2a9699f73ae414e35755fd2edd69983c8";
    hash = "sha256-44rpK8svPoKx/e/5aj0DpEfDbKuNjroKT4XUBpiOw2g=";
  };

  # drduh's patch folds in the changes published at
  # https://secure.research.vt.edu/diceware/ (local word lists, no CDN).
  patches = [ "${drduh-yubikey-guide}/share/drduh-yubikey-guide/diceware-vt.patch" ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    runHook postInstall
  '';

  meta = {
    description = "Static diceware passphrase generator web page, served offline";
    homepage = "https://github.com/grempe/diceware";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
