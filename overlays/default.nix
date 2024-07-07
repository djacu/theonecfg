inputs: {
  default = inputs.nixpkgs-unstable.lib.composeManyExtensions [

    inputs.nur.overlay

  ];

  "2405" = inputs.nixpkgs-unstable.lib.composeManyExtensions [

    inputs.agenix-2405.overlays.default

    (final: _: {
      # Override agenix CLI to use my wrapped version of age.
      theonecfg.agenix =
        (final.agenix.override { age = final.theonecfg.age; }).overrideAttrs (prevAttrs: {

          postPhases = [ "wrapPhase" ];

          nativeBuildInputs = (prevAttrs.nativeBuildInputs or [ ]) ++ [ final.makeWrapper ];

          wrapPhase = ''
            wrapProgram $out/bin/agenix \
              --set RULES ${../secrets/secrets.nix}
          '';

        });

      # Create my own modified age so that age-plugin-yubikey is on the path.
      theonecfg.age = final.age.overrideAttrs (prevAttrs: {
        nativeBuildInputs = (prevAttrs.nativeBuildInputs or [ ]) ++ [ final.makeWrapper ];

        postInstall =
          (prevAttrs.postInstall or "")
          + ''
            wrapProgram $out/bin/age \
              --set PATH ${final.lib.makeBinPath [ final.age-plugin-yubikey ]}
          '';
      });
    })

  ];
}
