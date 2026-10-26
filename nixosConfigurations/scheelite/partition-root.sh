#!/usr/bin/env bash

DISK=(
  "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0X208893V_1"
  "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0X208806D_1"
)
EFISIZE=10
SWAPSIZE=64
POOLNAME="scheelite-root"

partition_disk() {
  local disk="${1}"
  blkdiscard -f "${disk}" || true

  parted --script --align=optimal "${disk}" -- \
    mklabel gpt \
    mkpart EFI 1MiB $((EFISIZE))GiB \
    mkpart "${POOLNAME}" $((EFISIZE))GiB -$((SWAPSIZE))GiB \
    mkpart SWAP -$((SWAPSIZE))GiB 100% \
    set 1 esp on

  partprobe "${disk}"
}

for i in "${DISK[@]}"; do
  echo "${i}"
  partition_disk "${i}"
done

for i in "${DISK[@]}"; do
  mkswap "${i}-part3"
  swapon "${i}-part3"
done

# shellcheck disable=SC2046
zpool create \
  -o ashift=12 \
  -o autoexpand=on \
  -o autotrim=on \
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
  mirror \
  $(for i in "${DISK[@]}"; do
    printf '%s ' "${i}-part2"
  done)

zfs create \
  -o canmount=off \
  "${POOLNAME}"/local

zfs create \
  -o mountpoint=/ \
  "${POOLNAME}"/local/root

zfs snapshot "${POOLNAME}"/local/root@empty

mkdir -p "${MNT}/nix"
zfs create \
  -o mountpoint=/nix \
  "${POOLNAME}"/local/nix

zfs create \
  -o canmount=off \
  "${POOLNAME}"/safe

mkdir -p "${MNT}/home"
zfs create \
  -o mountpoint=/home \
  "${POOLNAME}"/safe/home

mkdir -p "${MNT}/persist"
zfs create \
  -o mountpoint=/persist \
  "${POOLNAME}"/safe/persist

for i in "${DISK[@]}"; do
  mkfs.vfat -n EFI "${i}"-part1
done

for i in "${DISK[@]}"; do
  mount -t vfat -o fmask=0077,dmask=0077,iocharset=iso8859-1,X-mount.mkdir "${i}"-part1 "${MNT}"/boot
  break
done
