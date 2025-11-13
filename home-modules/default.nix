inputs:
let
  inherit (inputs.self) library;

in
library.modules.mkUserModules inputs ./. "users"
