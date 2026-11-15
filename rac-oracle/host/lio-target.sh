#!/usr/bin/env bash
# host/lio-target.sh - the ASM LUNs of the RAC lab, exported over iSCSI.
#
# QEMU's file-backed SCSI disks are not a shared medium two cluster nodes can
# safely use, so the LUNs live on the host and are exported by an LIO iSCSI
# target. A single target keeps the on-disk ASM state coherent across
# `vagrant destroy` and gives the disks a stable by-path name on every node.
#
# Five LUNs, which is what a real two-node cluster uses:
#   ocr1..ocr3  2 GB each  -> ASM disk group OCR (NORMAL redundancy, 3 disks)
#   data        12 GB      -> ASM disk group DATA (datafiles, redo, control)
#   fra         8 GB       -> ASM disk group FRA (archive logs, backups)
#
# Usage: sudo ./host/lio-target.sh setup|status|teardown [--purge]
set -Eeuo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STORAGE_DIR=${RAC_LAB_STORAGE_DIR:-$LAB_DIR/.storage}
IQN=${RAC_LAB_ISCSI_IQN:-iqn.2026-11.lab.rac:asm}
PORTAL_IP=${RAC_LAB_STORAGE_IP:-10.40.3.1}
APT_PL_DIR=/etc/rtslib-fb-target/pr

# name:size in MB
LUNS=${RAC_LAB_LUNS:-"ocr1:2048 ocr2:2048 ocr3:2048 data:12288 fra:8192"}

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this script with sudo"
command -v targetcli >/dev/null || die "targetcli is not installed (package: targetcli-fb)"

create_backstore() {
  local name=$1 size_mb=$2 file="$STORAGE_DIR/$1.img"
  if [ ! -f "$file" ]; then
    # Sparse file: only written blocks consume space on the host.
    truncate -s "${size_mb}M" "$file"
    info "created $file (${size_mb} MB sparse)"
  fi
  if ! targetcli ls "/backstores/fileio/$name" >/dev/null 2>&1; then
    targetcli /backstores/fileio create name="$name" file_or_dev="$file" >/dev/null
    info "backstore $name"
  fi
  # ASM does not need persistent reservations, but leaving PR emulation on keeps
  # the LUNs usable with fence_scsi / I/O fencing experiments later.
  targetcli "/backstores/fileio/$name" set attribute emulate_pr=1 >/dev/null
}

add_lun() {
  local name=$1 luns="/iscsi/$IQN/tpg1/luns"
  if targetcli ls "$luns" 2>/dev/null | grep -q "fileio/$name"; then
    return 0
  fi
  targetcli "$luns" create "/backstores/fileio/$name" >/dev/null
  info "exported $name"
}

setup() {
  # rtslib keeps persistent-reservation metadata here; without the directory PR
  # commands fail with "logical unit communication failure".
  install -d -m 0700 "$APT_PL_DIR"
  install -d -m 0755 "$STORAGE_DIR"

  log "Creating the ASM LUNs"
  local spec name size_mb
  for spec in $LUNS; do
    name=${spec%%:*}
    size_mb=${spec##*:}
    create_backstore "$name" "$size_mb"
  done

  log "Publishing them through $IQN on $PORTAL_IP"
  if targetcli ls /iscsi 2>/dev/null | grep -qw "$IQN"; then
    info "target $IQN already exists"
  else
    targetcli /iscsi create "$IQN" >/dev/null || die "could not create the target"
    info "target $IQN created"
  fi

  for spec in $LUNS; do
    add_lun "${spec%%:*}"
  done

  # Answer only on the storage bridge: the default 0.0.0.0 portal would also
  # listen on the management and public networks. The bridge only exists once
  # `vagrant up` has created it, so before that the target keeps the wildcard
  # portal and this step narrows it when it is run again.
  if ip -4 -o addr show 2>/dev/null | grep -q " ${PORTAL_IP}/"; then
    if ! targetcli ls "/iscsi/$IQN/tpg1/portals" 2>/dev/null | grep -q "$PORTAL_IP"; then
      # The default wildcard portal binds dual-stack and LIO refuses a second
      # listener on port 3260 (kernel_bind EADDRINUSE), so it has to go first.
      # targetcli creates it as [::0] but only deletes it when spelled ::0.
      targetcli "/iscsi/$IQN/tpg1/portals" delete ::0 3260 >/dev/null 2>&1 || true
      targetcli "/iscsi/$IQN/tpg1/portals" delete 0.0.0.0 3260 >/dev/null 2>&1 || true
      targetcli "/iscsi/$IQN/tpg1/portals" create "$PORTAL_IP" >/dev/null \
        || die "could not create the $PORTAL_IP portal"
      info "portal $PORTAL_IP:3260"
    fi
  else
    warn "$PORTAL_IP does not exist on the host yet, keeping the 0.0.0.0 portal"
    info "run this again after 'vagrant up' to restrict it to the storage bridge"
  fi

  # Demo mode: no CHAP, no initiator ACLs. The storage bridge is isolated, but
  # this is the first thing to change for anything outside a lab.
  targetcli "/iscsi/$IQN/tpg1" set attribute \
    authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1 \
    >/dev/null || true

  targetcli saveconfig >/dev/null || die "could not save the target configuration"
  info "configuration saved to /etc/target/saveconfig.json"

  enable_boot_service
  status
}

# The LUNs must exist before any guest logs in, otherwise the nodes come up with
# a half-visible set of ASM disks.
enable_boot_service() {
  local unit=/etc/systemd/system/rac-iscsi-target.service
  cat > "$unit" <<EOF
[Unit]
Description=Oracle RAC lab iSCSI target ($IQN)
After=network-online.target target.service
Wants=network-online.target target.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/targetcli restoreconfig
ExecStop=/usr/bin/targetcli clearconfig confirm=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable rac-iscsi-target.service >/dev/null 2>&1 || true
  info "enabled rac-iscsi-target.service so the LUNs survive a host reboot"
}

status() {
  log "iSCSI target $IQN"
  targetcli ls "/iscsi/$IQN/tpg1" 2>/dev/null | sed 's/^/    /' || echo "    not configured"
  log "Backing files in $STORAGE_DIR"
  local spec file
  for spec in $LUNS; do
    file="$STORAGE_DIR/${spec%%:*}.img"
    if [ -f "$file" ]; then
      printf '    %-10s %s  (%s allocated)\n' "${spec%%:*}" "$file" \
        "$(du -h --apparent-size "$file" 2>/dev/null | cut -f1)"
    else
      printf '    %-10s missing\n' "${spec%%:*}"
    fi
  done
}

teardown() {
  log "Removing the iSCSI target"
  if targetcli ls /iscsi 2>/dev/null | grep -qw "$IQN"; then
    targetcli /iscsi delete "$IQN" >/dev/null 2>&1 || true
    info "target $IQN deleted"
  else
    info "target was not configured"
  fi
  local spec
  for spec in $LUNS; do
    targetcli /backstores/fileio delete "${spec%%:*}" >/dev/null 2>&1 || true
  done
  targetcli saveconfig >/dev/null 2>&1 || true
  systemctl disable rac-iscsi-target.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/rac-iscsi-target.service
  systemctl daemon-reload

  if [ "${1:-}" = "--purge" ]; then
    log "Deleting the LUN images"
    rm -f "$STORAGE_DIR"/*.img
    rmdir "$STORAGE_DIR" 2>/dev/null || true
    info "storage directory removed"
  else
    info "LUN images kept in $STORAGE_DIR (use --purge to delete them)"
  fi
}

case "${1:-setup}" in
  setup)    setup ;;
  status)   status ;;
  teardown) shift; teardown "${1:-}" ;;
  *)
    printf 'Usage: %s setup|status|teardown [--purge]\n' "$0" >&2
    exit 2
    ;;
esac
