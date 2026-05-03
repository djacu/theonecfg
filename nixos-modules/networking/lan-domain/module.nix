{ lib, ... }:
let

  inherit (lib.options)
    mkOption
    ;

  inherit (lib.types)
    str
    ;

in
{
  options.theonecfg.networking.lanDomain = mkOption {
    type = str;
    default = "lan";
    description = ''
      Base domain for LAN-internal services. Each service's `domain`
      option defaults to ''${serviceName}.''${lanDomain}, and AdGuard's
      wildcard rewrite covers the same suffix. Override per-host (e.g.
      "scheelite.lan").

      The default "lan" is RFC-6762's reserved LAN-only TLD recognized
      by most home routers and mDNS resolvers.
    '';
  };
}
