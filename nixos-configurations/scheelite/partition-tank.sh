DISK=(
  "/dev/disk/by-id/wwn-0x5000cca2902b7288"
  "/dev/disk/by-id/wwn-0x5000cca2902bcf64"
  "/dev/disk/by-id/wwn-0x5000cca2902be164"
  "/dev/disk/by-id/wwn-0x5000cca2902c39f4"
  "/dev/disk/by-id/wwn-0x5000cca2902c3a78"
  "/dev/disk/by-id/wwn-0x5000cca2902c3b14"
  "/dev/disk/by-id/wwn-0x5000cca2902c6ed0"
  "/dev/disk/by-id/wwn-0x5000cca2902c71c8"
)
POOLNAME="scheelite-tank0"

# shellcheck disable=SC2046
zpool create \
  -o ashift=12 \
  -o autoexpand=on \
  -R "${MNT}" \
  -O acltype=posix \
  -O atime=off \
  -O canmount=off \
  -O checksum=fletcher4 \
  -O compression=lz4 \
  -O dnodesize=auto \
  -O relatime=on \
  -O xattr=sa \
  -O mountpoint=none \
  "${POOLNAME}" \
  raidz3 \
  $(for i in "${DISK[@]}"; do
    printf '%s ' "${i}"
  done)

mkdir -p "${MNT}/tank0"
zfs create \
  -o mountpoint=/tank0 \
  "${POOLNAME}"/tank0

mkdir -p "${MNT}/tank0/video"
zfs create \
  -o recordsize=1M \
  -o mountpoint=/tank0/video \
  "${POOLNAME}"/tank0/video

mkdir -p "${MNT}/tank0/audio"
zfs create \
  -o recordsize=1M \
  -o mountpoint=/tank0/audio \
  "${POOLNAME}"/tank0/audio

mkdir -p "${MNT}/tank0/images"
zfs create \
  -o recordsize=1M \
  -o mountpoint=/tank0/images \
  "${POOLNAME}"/tank0/images

mkdir -p "${MNT}/tank0/bulk"
zfs create \
  -o mountpoint=/tank0/bulk \
  "${POOLNAME}"/tank0/bulk
