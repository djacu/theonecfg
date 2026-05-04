{ ... }:
{
  # Shared group for the media stack. Members are added per-module via
  # `users.users.<svc>.extraGroups = [ "media" ]`. Directories that need
  # cross-app rwx (e.g. /tank0/media/<type>, /tank0/downloads/<category>)
  # use sgid mode 2775 owned by `<primary>:media` so new subdirs/files
  # inherit the media group automatically.
  #
  # Why this group exists:
  # - *arr's default import flow is hardlink-then-delete-source, which
  #   needs write+delete on qBittorrent's downloads dir.
  # - Jellyfin (and any future read-only consumer) needs read on each
  #   *arr's rootFolders.
  # A single shared group with sgid is the standard homelab pattern;
  # avoids an N×M membership matrix as services are added.
  users.groups.media = { };
}
