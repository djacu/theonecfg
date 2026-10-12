inputs:
let

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    mapAttrs
    ;

  inherit (lib.trivial)
    const
    ;

in

mapAttrs (const (pkgs: {

  inherit (pkgs)
    diceware-page
    drduh-yubikey-guide
    ;

  inherit (pkgs.theonecfg)
    nom-check
    ;

})) inputs.self.legacyPackages
