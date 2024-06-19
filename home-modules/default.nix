inputs:
let
  inherit (inputs.nixpkgs-unstable.lib) filterAttrs genAttrs;

  inherit (builtins)
    attrNames
    map
    readDir
    removeAttrs
    ;

  knownUsers = [ "djacu" ];

  /**
    Get non-user directory names given a list of users and a path.

    # Example

      getNonUsers [ "djacu" ] ./.
      => { programs = "directory"; }

    # Type

    ```
    getNonUsers :: [String] -> Path -> [String]
    ```

    # Arguments

    - [users] User directories to remove.
    - [path] Path to the directory to read.
  */
  getNonUsers =
    users: path:
    attrNames (removeAttrs (filterAttrs (_: fileType: fileType == "directory") (readDir path)) users);

  /**
    Map strings to paths.
  */
  mapToPaths = map (elem: ./${elem});

  /**
    Make home modules for users.

    # Example

      mkUserModules [ "djacu" ]
      => { djacu = <homeModule>; }

    # Type

    ```
    mkUserModules :: [String] -> {<homeModule>}
    ```

    # Arguments

    - [users] Users for which to create home modules.
  */
  mkUserModules =
    users:
    let
      nonUserModules = mapToPaths (getNonUsers users ./.);
    in
    genAttrs users (userName: {
      imports = [ ./${userName} ] ++ nonUserModules;
      _module.args = {
        inherit inputs;
      };
    });
in
mkUserModules knownUsers
