/*
  Disko configuration for scheelite.

  Two pools:
    - scheelite-root  : 2-NVMe mirror, root FS + per-instance postgres datasets
    - scheelite-tank0 : 8-disk raidz3 (HGST via LSI HBA), bulk media + service state

  Pool properties match the original imperative setup scripts that created
  these pools (`partition-root.sh`, `partition-tank.sh`) so a fresh install
  via `nixos-anywhere` reproduces the same on-disk shape.

  New since the original layout:
    - safe/persist/postgres/<service>          per-instance postgres datasets, recordsize=8K
    - tank0/media/{tv,anime,movies,adult,music,audiobooks,books,photos,youtube}
    - tank0/downloads, tank0/services
    - jellyfin-cache as a separate dataset (so sanoid can exclude it from snapshots)

  Future-service media datasets (music, books, audiobooks) are pre-created
  per the homelab plan even though their consuming modules don't exist yet.
*/
{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0X208893V_1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "10G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "fmask=0077"
                  "dmask=0077"
                ];
              };
            };
            zfs = {
              # Everything between ESP and swap goes to scheelite-root.
              end = "-64G";
              content = {
                type = "zfs";
                pool = "scheelite-root";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
              };
            };
          };
        };
      };
      nvme1 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0X208806D_1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "10G";
              type = "EF00";
              # Mirror partition — only one ESP gets mounted at /boot;
              # the other is kept in sync manually if you care about
              # bootable failover. The disko module mounts only the first.
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-fallback";
                mountOptions = [
                  "fmask=0077"
                  "dmask=0077"
                ];
              };
            };
            zfs = {
              end = "-64G";
              content = {
                type = "zfs";
                pool = "scheelite-root";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
              };
            };
          };
        };
      };

      # raidz3 pool. ZFS uses whole disks (no partition table inside).
      tank0_d0 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902b7288";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d1 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902bcf64";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d2 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902be164";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d3 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902c39f4";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d4 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902c3a78";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d5 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902c3b14";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d6 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902c6ed0";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
      tank0_d7 = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000cca2902c71c8";
        content = {
          type = "zfs";
          pool = "scheelite-tank0";
        };
      };
    };

    zpool = {
      scheelite-root = {
        type = "zpool";
        mode = "mirror";
        # Property choices:
        #   compression=zstd: zstd has built-in LZ4-first early-abort
        #     (module/zstd/zfs_zstd.c) so incompressible data costs ~LZ4 and
        #     compressible data gets zstd ratio. Beats plain `lz4`.
        #   checksum=fletcher4: default; essentially free; cryptographic
        #     checksums (blake3/sha256) only matter for dedup/nopwrite/encryption.
        #   dedup=off: relying on nix.settings.auto-optimise-store for /nix/store
        #     (file-level hardlinks, captures the dominant duplication). ZFS
        #     block-level dedup adds DDT RAM cost for marginal gain.
        rootFsOptions = {
          acltype = "posix";
          atime = "off";
          canmount = "off";
          checksum = "fletcher4";
          compression = "zstd";
          dnodesize = "auto";
          relatime = "on";
          xattr = "sa";
          mountpoint = "none";
        };
        options = {
          ashift = "12";
          autoexpand = "on";
          autotrim = "on";
        };

        datasets = {
          local = {
            type = "zfs_fs";
            options.canmount = "off";
          };
          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options.mountpoint = "/";
            postCreateHook = ''
              zfs snapshot scheelite-root/local/root@empty
            '';
          };
          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.mountpoint = "/nix";
          };

          safe = {
            type = "zfs_fs";
            options.canmount = "off";
          };
          "safe/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options.mountpoint = "/home";
          };
          "safe/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
            options.mountpoint = "/persist";
          };

          # Per-instance postgres datasets — see scheelite-homelab-services.md.
          # recordsize=16K: vadosware.io benchmarks show 16K outperforms aligned
          # 8K (~24% TPS) by giving zstd a larger compression window without
          # introducing read amplification on postgres's 8K page reads. Pair
          # with `full_page_writes=off` + `wal_init_zero=off` + `wal_recycle=off`
          # in the postgres module (ZFS COW makes torn-page protection redundant).
          # Each dataset can be snapshotted/rolled back independently.
          "safe/persist/postgres" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres";
            options.mountpoint = "/persist/postgres";
            options.canmount = "off";
          };
          "safe/persist/postgres/nextcloud" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/nextcloud";
            options = {
              mountpoint = "/persist/postgres/nextcloud";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/immich" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/immich";
            options = {
              mountpoint = "/persist/postgres/immich";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/paperless" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/paperless";
            options = {
              mountpoint = "/persist/postgres/paperless";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/sonarr" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/sonarr";
            options = {
              mountpoint = "/persist/postgres/sonarr";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/sonarr-anime" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/sonarr-anime";
            options = {
              mountpoint = "/persist/postgres/sonarr-anime";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/radarr" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/radarr";
            options = {
              mountpoint = "/persist/postgres/radarr";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/whisparr" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/whisparr";
            options = {
              mountpoint = "/persist/postgres/whisparr";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/prowlarr" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/prowlarr";
            options = {
              mountpoint = "/persist/postgres/prowlarr";
              recordsize = "16K";
              atime = "off";
            };
          };
          "safe/persist/postgres/stasharr" = {
            type = "zfs_fs";
            mountpoint = "/persist/postgres/stasharr";
            options = {
              mountpoint = "/persist/postgres/stasharr";
              recordsize = "16K";
              atime = "off";
            };
          };
        };
      };

      scheelite-tank0 = {
        type = "zpool";
        mode = "raidz3";
        # See compression/checksum/dedup notes on scheelite-root above; same
        # rationale applies. Per-dataset overrides below for media (zstd-1
        # at recordsize=1M) and downloads (compression=off).
        rootFsOptions = {
          acltype = "posix";
          atime = "off";
          canmount = "off";
          checksum = "fletcher4";
          compression = "zstd";
          dnodesize = "auto";
          relatime = "on";
          xattr = "sa";
          mountpoint = "none";
        };
        options = {
          ashift = "12";
          autoexpand = "on";
        };

        datasets = {
          tank0 = {
            type = "zfs_fs";
            mountpoint = "/tank0";
            options.mountpoint = "/tank0";
          };

          # Hierarchical media datasets, recordsize=1M for sequential reads
          # of large media files. compression=zstd-1 (faster than lz4 default
          # and gives slightly better ratios on already-compressed media).
          "tank0/media" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media";
            options = {
              mountpoint = "/tank0/media";
              recordsize = "1M";
              compression = "zstd-1";
            };
          };
          "tank0/media/tv" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/tv";
            options.mountpoint = "/tank0/media/tv";
          };
          "tank0/media/anime" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/anime";
            options.mountpoint = "/tank0/media/anime";
          };
          "tank0/media/movies" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/movies";
            options.mountpoint = "/tank0/media/movies";
          };
          "tank0/media/adult" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/adult";
            options.mountpoint = "/tank0/media/adult";
          };
          "tank0/media/music" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/music";
            options.mountpoint = "/tank0/media/music";
          };
          "tank0/media/audiobooks" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/audiobooks";
            options.mountpoint = "/tank0/media/audiobooks";
          };
          "tank0/media/books" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/books";
            options.mountpoint = "/tank0/media/books";
          };
          "tank0/media/photos" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/photos";
            options.mountpoint = "/tank0/media/photos";
          };
          "tank0/media/youtube" = {
            type = "zfs_fs";
            mountpoint = "/tank0/media/youtube";
            options.mountpoint = "/tank0/media/youtube";
          };

          # Downloads — recordsize=1M, compression off (torrents are
          # already compressed; trying again wastes CPU).
          "tank0/downloads" = {
            type = "zfs_fs";
            mountpoint = "/tank0/downloads";
            options = {
              mountpoint = "/tank0/downloads";
              recordsize = "1M";
              compression = "off";
            };
          };

          # Per-service state datasets — default recordsize, lz4 compression.
          # Each service module's tmpfiles creates its own subdirectory with
          # the right ownership.
          "tank0/services" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services";
            options.mountpoint = "/tank0/services";
          };
          "tank0/services/jellyfin" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/jellyfin";
            options.mountpoint = "/tank0/services/jellyfin";
          };
          "tank0/services/jellyfin-cache" = {
            # Separate dataset so a snapshot policy can exclude it (cache is
            # regenerable; no value snapshotting it).
            type = "zfs_fs";
            mountpoint = "/tank0/services/jellyfin-cache";
            options.mountpoint = "/tank0/services/jellyfin-cache";
          };
          "tank0/services/sonarr" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/sonarr";
            options.mountpoint = "/tank0/services/sonarr";
          };
          "tank0/services/sonarr-anime" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/sonarr-anime";
            options.mountpoint = "/tank0/services/sonarr-anime";
          };
          "tank0/services/stash" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/stash";
            options = {
              mountpoint = "/tank0/services/stash";
              recordsize = "16K";
              atime = "off";
            };
          };
          "tank0/services/radarr" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/radarr";
            options.mountpoint = "/tank0/services/radarr";
          };
          "tank0/services/stasharr" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/stasharr";
            options.mountpoint = "/tank0/services/stasharr";
          };
          "tank0/services/whisparr" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/whisparr";
            options.mountpoint = "/tank0/services/whisparr";
          };
          "tank0/services/prowlarr" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/prowlarr";
            options.mountpoint = "/tank0/services/prowlarr";
          };
          "tank0/services/qbittorrent" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/qbittorrent";
            options.mountpoint = "/tank0/services/qbittorrent";
          };
          "tank0/services/nextcloud" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/nextcloud";
            options.mountpoint = "/tank0/services/nextcloud";
          };
          "tank0/services/paperless" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/paperless";
            options.mountpoint = "/tank0/services/paperless";
          };
          "tank0/services/grafana" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/grafana";
            options.mountpoint = "/tank0/services/grafana";
          };
          "tank0/services/prometheus" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/prometheus";
            options.mountpoint = "/tank0/services/prometheus";
          };
          "tank0/services/loki" = {
            type = "zfs_fs";
            mountpoint = "/tank0/services/loki";
            options.mountpoint = "/tank0/services/loki";
          };
        };
      };
    };
  };
}
