#!/usr/bin/env bash
# host/lio-target.sh - shared LUNs for the VCS lab, exported over iSCSI.
#
# QEMU's file-backed SCSI disks do not implement SCSI-3 persistent
# reservations (no pr-manager on scsi-hd), which VXFEN needs in order to fence
# a failed node. LIO's fileio backstore emulates persistent reservations
# (emulate_pr=1), so the cluster nodes attach the LUNs over iSCSI instead of
# using libvirt shared disks.
#
# Usage: sudo ./host/lio-target.sh setup|status|teardown [--purge]
set -Eeuo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STORAGE_DIR=${VCS_LAB_STORAGE_DIR:-$LAB_DIR/.storage}
IQN=${VCS_LAB_ISCSI_IQN:-iqn.2026-11.lab.vcs:storage}
DATA_MB=${VCS_LAB_SHARED_MB:-8192}
COORD_MB=${VCS_LAB_COORD_MB:-1024}
# VXFEN wants an odd number of coordination points; Veritas recommends three.
COORD_COUNT=${VCS_LAB_COORD_COUNT:-3}
APT_PL_DIR=/etc/rtslib-fb-target/pr

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this script with sudo"
command -v targetcli >/dev/null || die "targetcli is not installed (package: targetcli-fb)"

create_backstore() {
  local name=$1 size_mb=$2 file="$STORAGE_DIR/$1.img"
  if [ ! -f "$file" ]; then
    # Sparse file: the guest only consumes space for blocks that are written.
    truncate -s "${size_mb}M" "$file"
  fi
  if ! targetcli ls "/backstores/fileio/$name" >/dev/null 2>&1; then
    targetcli /backstores/fileio create name="$name" file_or_dev="$file" >/dev/null
  fi
  # emulate_pr is what makes the LUN usable as a VXFEN coordinator.
  targetcli "/backstores/fileio/$name" set attribute emulate_pr=1 >/dev/null
  info "$name -> $file (${size_mb} MB)"
}

add_lun() {
  local name=$1 luns="/iscsi/$IQN/tpg1/luns"
  if ! targetcli ls "$luns" 2>/dev/null | grep -q "fileio/$name"; then
    targetcli "$luns" create "/backstores/fileio/$name" >/dev/null
  fi
  info "LUN for $name exported"
}

setup() {
  # rtslib stores persistent-reservation metadata here; without the directory
  # every PR command fails with "logical unit communication failure".
  install -d -m 0700 "$APT_PL_DIR"
  install -d -m 0755 "$STORAGE_DIR"

  log "Creating the shared LUNs"
  create_backstore data "$DATA_MB"
  local i
  for i in $(seq 1 "$COORD_COUNT"); do
    create_backstore "coord$i" "$COORD_MB"
  done

  log "Publishing them through $IQN"
  if ! targetcli ls "/iscsi/$IQN" >/dev/null 2>&1; then
    targetcli /iscsi create "$IQN" >/dev/null
  fi
  add_lun data
  for i in $(seq 1 "$COORD_COUNT"); do
    add_lun "coord$i"
  done

  # Lab-only access control: any initiator may log in, no CHAP. The portal is
  # only reachable over the host-only cluster network.
  targetcli "/iscsi/$IQN/tpg1" set attribute \
    authentication=0 generate_node_acls=1 demo_mode_write_protect=0 \
    cache_dynamic_acls=1 >/dev/null

  systemctl enable target.service >/dev/null 2>&1 || true
  targetcli saveconfig >/dev/null
  log "iSCSI target ready on port 3260"
  info "initiators connect to <client-network-gateway>:3260 and log in to $IQN"
}

status() {
  targetcli ls 2>/dev/null | sed 's/^/    /'
  echo
  ls -lh "$STORAGE_DIR" 2>/dev/null | sed 's/^/    /'
}

teardown() {
  log "Removing all LIO targets and backstores"
  targetcli clearconfig confirm=True >/dev/null 2>&1 || true
  targetcli saveconfig >/dev/null 2>&1 || true
  if [ "${1:-}" = "--purge" ]; then
    log "Deleting $STORAGE_DIR"
    rm -rf "$STORAGE_DIR"
  else
    info "kept $STORAGE_DIR (use --purge to delete the data)"
  fi
}

case "${1:-}" in
  setup)    setup ;;
  status)   status ;;
  teardown) shift; teardown "${1:-}" ;;
  *)        die "usage: $0 setup|status|teardown [--purge]" ;;
esac
