inputs: {
  default = inputs.nixpkgs-unstable.lib.composeManyExtensions [

    inputs.nur.overlay

    # Create my own modified age so that age-plugin-yubikey is on the path.
    (final: _: {
      theonecfg.age = final.age.overrideAttrs (prevAttrs: {
        nativeBuildInputs = (prevAttrs.nativeBuildInputs or [ ]) + [ final.makeWrapper ];

        postInstall =
          (prevAttrs.postInstall or "")
          + ''
            wrapProgram $out/bin/age \
              --prefix PATH : ${final.lib.makeBinPath [ final.age-plugin-yubikey ]}
          '';
      });
    })

  ];
}
