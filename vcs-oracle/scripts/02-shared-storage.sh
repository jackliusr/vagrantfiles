#!/usr/bin/env bash
# 02-shared-storage.sh - attaches the shared LUNs and prepares the data volume.
#
# The LUNs come from the LIO iSCSI target on the host (host/lio-target.sh):
#   LUN 0 - data disk for vg_ora (Oracle datafiles, redo, SPFILE, archivelogs)
#   LUN 1 - VXFEN coordinator disk 1
#   LUN 2 - VXFEN coordinator disk 2
# LIO emulates SCSI-3 persistent reservations, which is what makes I/O fencing
# possible on this virtual setup.
#
# Node vcs1 creates the LVM volume group on LUN 0; vcs2 only verifies that it
# can see it. VCS activates the volume group when the service group goes online.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_STORAGE_IP:?LAB_STORAGE_IP is not set}"
: "${LAB_STORAGE_IQN:?LAB_STORAGE_IQN is not set}"

VG_NAME=vg_ora
LV_NAME=lv_u02
MOUNT_POINT=/u02
SHARED_DISK_MB=${LAB_SHARED_DISK_MB:-8192}
COORD_DISK_MB=${LAB_COORD_DISK_MB:-1024}
BY_PATH="/dev/disk/by-path/ip-${LAB_STORAGE_IP}:3260-iscsi-${LAB_STORAGE_IQN}-lun-"

log "Logging in to the shared storage target on $LAB_STORAGE_IP"
echo "InitiatorName=iqn.2026-11.lab.vcs:$LAB_NODE" > /etc/iscsi/initiatorname.iscsi
systemctl enable --now iscsid >/dev/null 2>&1 || die "could not start iscsid"

if ! iscsiadm -m node -T "$LAB_STORAGE_IQN" -p "$LAB_STORAGE_IP" >/dev/null 2>&1; then
  iscsiadm -m discovery -t st -p "$LAB_STORAGE_IP" >/dev/null \
    || die "iSCSI discovery against $LAB_STORAGE_IP failed (is ./host/lio-target.sh setup running?)"
fi
iscsiadm -m node -T "$LAB_STORAGE_IQN" -p "$LAB_STORAGE_IP" \
  -o update -n node.startup -v automatic >/dev/null
iscsiadm -m node -T "$LAB_STORAGE_IQN" -p "$LAB_STORAGE_IP" --login >/dev/null 2>&1 || true
iscsiadm -m session >/dev/null 2>&1 || die "no iSCSI session to $LAB_STORAGE_IP"
# Pick up LUNs that were added to the target after the initial login. The
# kernel scans asynchronously, so give the device nodes time to appear below.
for sid in $(iscsiadm -m session 2>/dev/null | sed -n 's/.*\[\([0-9]*\)\].*/\1/p'); do
  iscsiadm -m session -r "$sid" --rescan >/dev/null 2>&1 || true
done
systemctl enable iscsi >/dev/null 2>&1 || true
udevadm settle --timeout=30

log "Locating the shared LUNs"
disk_by_lun() {
  local lun=$1 size_mb=$2 link="$BY_PATH$1" dev size
  for _ in $(seq 1 60); do
    [ -e "$link" ] && break
    sleep 1
  done
  [ -e "$link" ] || return 1
  dev=$(readlink -f "$link")
  size=$(( $(blockdev --getsize64 "$dev") / 1024 / 1024 ))
  if [ "$size" -lt $((size_mb - 64)) ] || [ "$size" -gt $((size_mb + 64)) ]; then
    die "LUN $lun ($dev) is ${size} MB, expected about ${size_mb} MB"
  fi
  printf '%s\n' "$dev"
}

LAB_DATA_DISK=$(disk_by_lun 0 "$SHARED_DISK_MB") \
  || die "data LUN 0 is not present; check the iSCSI target"

# VXFEN wants an odd number of coordination points; the host exports three.
coord_disks=""
lun=1
while disk=$(disk_by_lun "$lun" "$COORD_DISK_MB" 2>/dev/null); do
  coord_disks="$coord_disks $disk"
  lun=$((lun + 1))
  [ "$lun" -gt 8 ] && break
done
LAB_COORD_DISKS=${coord_disks# }
[ -n "$LAB_COORD_DISKS" ] || die "no coordinator LUNs found; check the iSCSI target"
info "data=$LAB_DATA_DISK coordinator disks=$LAB_COORD_DISKS"

# LVM caches the device list at boot; the iSCSI disks log in after the cache is
# built, so rescan explicitly.
pvscan --cache >/dev/null 2>&1 || true

if [ "$LAB_ROLE" = "primary" ]; then
  log "Creating the shared volume group and filesystem"
  if vgs --noheadings "$VG_NAME" >/dev/null 2>&1; then
    info "volume group $VG_NAME already exists"
  else
    pvcreate --yes --force "$LAB_DATA_DISK"
    vgcreate --yes "$VG_NAME" "$LAB_DATA_DISK"
    lvcreate --yes --extents 100%FREE --name "$LV_NAME" "$VG_NAME"
    mkfs.ext4 -q -m 1 -L u02 "/dev/$VG_NAME/$LV_NAME"
  fi

  vgchange --activate y "$VG_NAME" >/dev/null
  install -d -m 0755 "$MOUNT_POINT"
  if mountpoint -q "$MOUNT_POINT"; then
    info "$MOUNT_POINT is already mounted"
  else
    mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"
  fi
  df -h "$MOUNT_POINT" | sed 's/^/    /'
else
  log "Verifying that the shared volume group is visible"
  # The passive node must not have the volume group online; VCS owns
  # activation once the service group is configured.
  vgchange --activate n "$VG_NAME" >/dev/null 2>&1 || true
  vgs "$VG_NAME" || die "node cannot see volume group $VG_NAME; check the iSCSI session and LVM filters"
  if [ "$(lvs --noheadings -o lv_active "/dev/$VG_NAME/$LV_NAME" | tr -d ' ')" = "active" ]; then
    warn "/dev/$VG_NAME/$LV_NAME is still active on this node"
  else
    info "/dev/$VG_NAME/$LV_NAME is present and inactive (as expected)"
  fi
fi

save_lab_env
mark_done storage
log "Shared storage prepared"
