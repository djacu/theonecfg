/**
  Shared option types for declarative *arr / Jellyfin REST configuration.
  Used by sonarr, radarr, whisparr, prowlarr, jellyfin, jellyseerr modules.

  Most *arr resources (indexers, applications, downloadClients, etc.) have
  varying schemas per-implementation. Rather than enumerate every variant,
  we use freeform submodules that match the *arr API JSON shape directly.
  Users look up the schema via GET /<endpoint>/schema and put the resulting
  attrs into Nix verbatim.
*/
{ lib }:
let
  inherit (lib.types)
    attrsOf
    lazyAttrsOf
    listOf
    str
    submodule
    unspecified
    ;

  inherit (lib.options)
    mkOption
    ;

  /**
    A submodule that allows arbitrary attributes (matching whatever JSON the
    *arr API expects), with at least a `name` field used as the diff
    comparator by `mkArrApiPushService`.
  */
  freeformWithName = submodule {
    freeformType = lazyAttrsOf unspecified;
    options = {
      name = mkOption {
        type = str;
        description = ''
          Name of the resource. Used by the API-push helper as the
          comparator for diff/reconcile (POST if missing, PUT if present
          with same name).
        '';
      };
    };
  };

in
{
  /**
    Root folder type for *arr services.
    POST /api/v3/rootfolder body: `{ "path": "/tank0/media/tv" }`.
    The `path` value is also used as the comparator (no `name` field on
    rootfolders).
  */
  rootFolderType = submodule {
    options.path = mkOption {
      type = str;
      description = "Filesystem path for the root folder.";
      example = "/tank0/media/tv";
    };
  };

  /**
    Indexer type for Prowlarr.
    Refer to GET /api/v1/indexer/schema for the full set of fields per
    implementation. Common keys: name, implementation, configContract,
    fields ([{name, value}, ...]), tags, priority, enable.
  */
  indexerType = freeformWithName;

  /**
    Application type for Prowlarr (the Sonarr/Radarr/Whisparr/Lidarr/Readarr
    instances that Prowlarr pushes indexers to).
    Schema: GET /api/v1/applications/schema.
  */
  applicationType = freeformWithName;

  /**
    Download client type for Sonarr/Radarr/Whisparr/Prowlarr.
    Schema: GET /api/v3/downloadclient/schema (or /api/v1/downloadclient
    for Prowlarr).
  */
  downloadClientType = freeformWithName;

  /**
    Delay profile type for Sonarr-family services.
    Comparator is `tags` (a delay profile is identified by which tags it
    applies to). For our use we usually have one default profile.
  */
  delayProfileType = submodule {
    freeformType = lazyAttrsOf unspecified;
    options = {
      tags = mkOption {
        type = listOf str;
        default = [ ];
        description = "Tags this delay profile applies to.";
      };
    };
  };

  /**
    Jellyfin library type (= virtual folder).
    Posted to /Library/VirtualFolders.
  */
  jellyfinLibraryType = submodule {
    options = {
      paths = mkOption {
        type = listOf str;
        description = "Filesystem paths Jellyfin scans for this library.";
      };
      type = mkOption {
        type = str;
        description = "Jellyfin collection type.";
        example = "tvshows";
      };
      options = mkOption {
        type = attrsOf unspecified;
        default = { };
        description = "Library-specific options posted as JSON body.";
      };
    };
  };
}
