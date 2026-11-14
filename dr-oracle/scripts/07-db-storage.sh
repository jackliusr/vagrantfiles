#!/usr/bin/env bash
# 07-db-storage.sh - attaches the site's array to its database host.
#
# Site A owns the live filesystems, so this step creates them (first run) and
# mounts them. At site B the array is a replication target and does not present
# any LUN, so the host only logs in and waits: the devices appear when the array
# is promoted, and dr-action.sh start-db rescans for them at that point.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/dr-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_SITE:?LAB_SITE is not set}"
: "${LAB_SITE_ROLE:?LAB_SITE_ROLE is not set}"
: "${LAB_SAN_IP:?LAB_SAN_IP is not set}"
: "${LAB_ISCSI_IQN:?LAB_ISCSI_IQN is not set}"
: "${LAB_ORACLE_SID:?LAB_ORACLE_SID is not set}"

SID=${LAB_ORACLE_SID}

log "Logging in to the site $LAB_SITE array ($LAB_SAN_IP, $LAB_ISCSI_IQN)"
iscsiadm -m discovery -t sendtargets -p "$LAB_SAN_IP" >/dev/null 2>&1 \
  || die "iSCSI discovery against $LAB_SAN_IP failed - is the array running and the SAN network up?"
iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" \
  -o update -n node.startup -v automatic >/dev/null 2>&1 || warn "could not set node.startup=automatic"
iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" --login >/dev/null 2>&1 || true
iscsiadm -m session --rescan >/dev/null 2>&1 || true

# The by-path links are deterministic, whether or not the LUN is presented now.
LAB_LUN0=$(lun_by_path 0)
LAB_LUN1=$(lun_by_path 1)
export LAB_LUN0 LAB_LUN1
save_lab_env

fstab_entry() {
  local label=$1 target=$2
  grep -q "LABEL=$label" /etc/fstab && return 0
  printf 'LABEL=%s %s ext4 noauto 0 2\n' "$label" "$target" >> /etc/fstab
  info "added the LABEL=$label -> $target entry to /etc/fstab (noauto)"
}

ensure_filesystem() {
  local label=$1 dev=$2 current
  current=$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)
  if [ "$current" = "$label" ]; then
    info "$dev already carries LABEL=$label"
    return 0
  fi
  if [ -n "$current" ]; then
    warn "$dev carries LABEL=$current, re-creating it as $label"
  fi
  log "Creating the $label filesystem on $dev"
  mkfs.ext4 -q -L "$label" -m 1 "$dev" || die "mkfs.ext4 $dev failed"
}

if [ "$LAB_SITE_ROLE" = "primary" ]; then
  wait_until 120 "LUN 0 ($LAB_LUN0)" test -e "$LAB_LUN0" || die "the data LUN was never presented"
  wait_until 120 "LUN 1 ($LAB_LUN1)" test -e "$LAB_LUN1" || die "the archive LUN was never presented"
  info "data LUN:    $LAB_LUN0 -> $(readlink -f "$LAB_LUN0")"
  info "archive LUN: $LAB_LUN1 -> $(readlink -f "$LAB_LUN1")"

  log "Preparing the live filesystems at site $LAB_SITE"
  ensure_filesystem oradata "$LAB_LUN0"
  ensure_filesystem orafra  "$LAB_LUN1"

  mountpoint -q /u02 || mount -L oradata /u02 || die "could not mount /u02"
  mountpoint -q /u03 || mount -L orafra  /u03 || die "could not mount /u03"
  fstab_entry oradata /u02
  fstab_entry orafra  /u03

  install -d -m 0775 -o oracle -g oinstall \
    /u02/app/oracle/oradata \
    "/u02/app/oracle/admin/$SID/adump" \
    "/u02/app/oracle/admin/$SID/pfile" \
    /u03/app/oracle/fast_recovery_area
  chown oracle:oinstall /u02/app /u02/app/oracle /u03/app /u03/app/oracle
  info "/u02 and /u03 mounted"
else
  fstab_entry oradata /u02
  fstab_entry orafra  /u03
  if [ -e "$LAB_LUN0" ]; then
    # The array is already Primary at this site (re-run after a failover).
    label=$(blkid -o value -s LABEL "$LAB_LUN0" 2>/dev/null || true)
    info "the site $LAB_SITE array is presenting LUNs (LABEL=${label:-none})"
  else
    info "no LUN is presented at the DR site (expected: the array is a replication target)"
    info "after ./lab failover the LUNs appear and start-db rescans for them"
  fi
  info "the replicated copy is validated on the array itself: ./lab storage runs"
  info "dr-action.sh verify-replica before this step"
fi

mark_done db_storage
log "Storage ready on $LAB_NODE"
