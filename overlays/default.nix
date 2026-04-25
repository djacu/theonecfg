inputs:
let

  # inherits

  inherit (inputs.nixpkgs-lib)
    lib
    ;

  inherit (lib.attrsets)
    attrValues
    genAttrs
    ;

  inherit (lib.filesystem)
    packagesFromDirectoryRecursive
    ;

  inherit (lib.fixedPoints)
    composeManyExtensions
    ;

  inherit (inputs.self.library.path)
    getDirectoryNames
    joinParentToPaths
    ;

  # overlays

  fixes = final: prev: {
    pythonPackagesExtensions = prev.pythonPackagesExtensions or [ ] ++ [
      (finalPython: prevPython: {
        aioboto3 = prevPython.aioboto3.overrideAttrs (prevAttrs: {
          disabledTests = prevAttrs.disabledTests or [ ] ++ [
            "test_dynamo_resource_query"
            "test_dynamo_resource_put"
            "test_dynamo_resource_batch_write_flush_on_exit_context"
            "test_dynamo_resource_batch_write_flush_amount"
            "test_flush_doesnt_reset_item_buffer"
            "test_dynamo_resource_property"
            "test_dynamo_resource_waiter"
          ];
        });
      })
    ];
  };

  toplevelOverlays =
    final: prev:
    packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      inherit (prev) newScope;
      directory = ../package-sets/top-level;
    };

  packageOverrides =
    (
      parent:
      (genAttrs (getDirectoryNames parent) (
        dir:
        import (
          joinParentToPaths parent [
            dir
            "overlay.nix"
          ]
        )
      ))
    )
      ./package-overrides;

  inputOverlays = genAttrs (getDirectoryNames ../overlays/input-overlays) (
    dir: import ../overlays/input-overlays/${dir}/overlay.nix inputs
  );

in
packageOverrides
// inputOverlays
// {

  default = composeManyExtensions (
    (attrValues packageOverrides)
    ++ [
      inputs.nur.overlays.default
      toplevelOverlays
      fixes
    ]
    ++ (attrValues inputOverlays)
  );

}
