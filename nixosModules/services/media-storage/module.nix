{ ... }:
{
  # Shared group for the media stack. Members are added per-module via
  # `users.users.<svc>.extraGroups = [ "media" ]`. Directories that need
  # cross-app rwx (e.g. /tank0/media/<type>, /tank0/downloads/<category>)
  # use sgid mode 2775 owned by `<primary>:media` so new subdirs/files
  # inherit the media group automatically.
  #
  # Why this group exists:
  # - *arr reads the release from qBittorrent's downloads dir to import
  #   it, and needs write+delete there to clean up the source afterward.
  #   NOTE: the import is a full *copy*, not a hardlink — /tank0/downloads
  #   and /tank0/media/* are separate ZFS datasets (different filesystems),
  #   so hardlinks can't cross them. See scheelite disko.nix.
  # - Jellyfin (and any future read-only consumer) needs read on each
  #   *arr's rootFolders.
  # A single shared group with sgid is the standard homelab pattern;
  # avoids an N×M membership matrix as services are added.
  users.groups.media = { };
}
