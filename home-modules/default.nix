inputs:
let
  inherit (inputs.self) library;

  knownUsers = [ "djacu" ];

in
library.modules.mkUserModules knownUsers ./.
