#!/usr/bin/env bash
# 02-shared-storage.sh - attaches the iSCSI LUNs and prepares the data volume.
#
# The LUNs come from the LIO iSCSI target on the host (host/lio-target.sh):
#   LUN 0 - data disk, holds vg_ora with the Oracle datafiles and SPFILE
#   LUN 1 - SBD device used for node fencing
#
# Node ha1 creates the LVM volume group on LUN 0; ha2 only verifies that it can
# see it. Pacemaker activates the volume group when the resource group starts.
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
DATA_MB=${LAB_DATA_MB:-8192}
SBD_MB=${LAB_SBD_MB:-1024}
BY_PATH="/dev/disk/by-path/ip-${LAB_STORAGE_IP}:3260-iscsi-${LAB_STORAGE_IQN}-lun-"

log "Logging in to the shared storage target on $LAB_STORAGE_IP"
echo "InitiatorName=iqn.2026-11.lab.rhelha:$LAB_NODE" > /etc/iscsi/initiatorname.iscsi
systemctl enable --now iscsid >/dev/null 2>&1 || die "could not start iscsid"

if ! iscsiadm -m node -T "$LAB_STORAGE_IQN" -p "$LAB_STORAGE_IP" >/dev/null 2>&1; then
  iscsiadm -m discovery -t st -p "$LAB_STORAGE_IP" >/dev/null \
    || die "iSCSI discovery against $LAB_STORAGE_IP failed (is ./host/lio-target.sh setup running?)"
fi
iscsiadm -m node -T "$LAB_STORAGE_IQN" -p "$LAB_STORAGE_IP" \
  -o update -n node.startup -v automatic >/dev/null
iscsiadm -m node -T "$LAB_STORAGE_IQN" -p "$LAB_STORAGE_IP" --login >/dev/null 2>&1 || true
iscsiadm -m session >/dev/null 2>&1 || die "no iSCSI session to $LAB_STORAGE_IP"
# Pick up LUNs that were added to the target after the initial login.
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
  # Return the stable /dev/disk/by-path link: /dev/sdX can change order across
  # reboots, and SBD writes the path we give it into /etc/sysconfig/sbd.
  printf '%s\n' "$link"
}

LAB_DATA_DISK=$(disk_by_lun 0 "$DATA_MB") || die "data LUN 0 is not present; check the iSCSI target"
LAB_SBD_DISK=$(disk_by_lun 1 "$SBD_MB")   || die "SBD LUN 1 is not present; check the iSCSI target"
info "data=$LAB_DATA_DISK sbd=$LAB_SBD_DISK"

# RHEL 9 restricts LVM to the devices listed in /etc/lvm/devices/system.devices.
# iSCSI LUNs are not in that file on a fresh node, so add ours explicitly; the
# entry is keyed by WWID, which keeps working if the sdX name changes.
lvmdevices --adddev "$LAB_DATA_DISK" >/dev/null 2>&1 || true

# LVM also caches the device list at boot; the iSCSI disks log in afterwards.
pvscan --cache >/dev/null 2>&1 || true

if [ "$LAB_ROLE" = "primary" ]; then
  log "Creating the shared volume group and filesystem"
  if vgs --noheadings "$VG_NAME" >/dev/null 2>&1; then
    info "volume group $VG_NAME already exists"
  else
    pvcreate --yes --force "$LAB_DATA_DISK"
    # A system ID is what lets LVM-activate's system_id mode move the volume
    # group between nodes (see 06-cluster.sh).
    vgcreate --yes --system-id "$(hostname -s)" "$VG_NAME" "$LAB_DATA_DISK"
    lvcreate --yes --extents 100%FREE --name "$LV_NAME" "$VG_NAME"
    mkfs.ext4 -q -m 1 -L u02 "/dev/$VG_NAME/$LV_NAME"
  fi
  if [ -z "$(vgs --noheadings -o systemid "$VG_NAME" | tr -d ' ')" ]; then
    info "adding a system ID to $VG_NAME"
    vgchange --systemid "$(hostname -s)" "$VG_NAME" >/dev/null
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
  # The primary may still be creating the volume group when the nodes are
  # provisioned in parallel, so give it a moment.
  for _ in $(seq 1 12); do
    vgs --foreign "$VG_NAME" >/dev/null 2>&1 && break
    pvscan --cache >/dev/null 2>&1 || true
    sleep 5
  done
  # The nodes are provisioned in parallel, so on a first run the primary may
  # not have created the volume group yet. 06-cluster.sh checks again before
  # the resource group is created.
  #
  # The VG carries the primary's LVM system ID, so LVM reports it as foreign
  # here and refuses to activate it - which is exactly what we want. The
  # LVM-activate resource agent rewrites the system ID when the group moves.
  if vgs --foreign --noheadings "$VG_NAME" >/dev/null 2>&1; then
    info "volume group $VG_NAME is visible (system ID: $(vgs --foreign --noheadings -o systemid "$VG_NAME" | tr -d ' '))"
  else
    warn "volume group $VG_NAME is not visible yet (it is created by the primary)"
  fi
fi

# SBD must be able to open its device after the iSCSI login at boot.
if [ -d /usr/lib/systemd/system ] && systemctl cat sbd >/dev/null 2>&1; then
  install -d -m 0755 /etc/systemd/system/sbd.service.d
  cat > /etc/systemd/system/sbd.service.d/after-iscsi.conf <<'EOF'
[Unit]
Wants=iscsid.service iscsi.service
After=iscsid.service iscsi.service network-online.target
EOF
  systemctl daemon-reload
  info "ordered sbd.service after the iSCSI login"
fi

save_lab_env
mark_done storage
log "Shared storage prepared"
