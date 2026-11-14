#!/usr/bin/env bash
# 07-vcs-config.sh - builds the VCS cluster and the ora_sg service group.
#
# Run this on the primary node once both nodes are up and 06-vcs-install.sh has
# finished on both. The script releases the shared volume, configures I/O
# fencing (VXFEN) when the coordinator LUNs support SCSI-3 persistent
# reservations, writes main.cf, validates it with hacf, copies it to the peer
# and starts VCS on both nodes.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_PEER_CLIENT_IP:?LAB_PEER_CLIENT_IP is not set}"
: "${LAB_CLIENT_NIC:?LAB_CLIENT_NIC is not set}"
: "${LAB_SERVICE_IP:?LAB_SERVICE_IP is not set}"
: "${LAB_CLUSTER_NAME:?LAB_CLUSTER_NAME is not set}"

VCS_CONF=/etc/VRTSvcs/conf/config
VCS_BIN=/opt/VRTSvcs/bin
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID:-orcl}
VG_NAME=vg_ora
BLOCK_DEVICE=/dev/mapper/vg_ora-lv_u02
MOUNT_POINT=/u02
NETMASK=${LAB_NETMASK:-255.255.255.0}
PEER="root@$LAB_PEER_CLIENT_IP"

if [ "$LAB_ROLE" != "primary" ]; then
  info "the cluster is created from the primary node; nothing to do on $LAB_NODE"
  exit 0
fi

if step_done vcs_config; then
  info "cluster configuration already completed"
  exit 0
fi

log "Checking that both nodes are ready"
[ -x "$VCS_BIN/hacf" ] || die "VCS is not installed on $LAB_NODE (run 06-vcs-install.sh)"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" true 2>/dev/null \
  || die "passwordless SSH to $LAB_PEER_CLIENT_IP is not working"
ssh "$PEER" 'test -x /opt/VRTSvcs/bin/hacf' \
  || die "VCS is not installed on $LAB_PEER (run 06-vcs-install.sh)"
ssh "$PEER" '/sbin/lltconfig >/dev/null' || die "LLT is not running on $LAB_PEER"

peer_nic=$(ssh "$PEER" '. /etc/vcs-lab/lab.env 2>/dev/null; printf "%s" "$LAB_CLIENT_NIC"')
[ "$peer_nic" = "$LAB_CLIENT_NIC" ] \
  || die "client interface differs between nodes ($LAB_CLIENT_NIC vs $peer_nic); main.cf needs the same name on both"

if mountpoint -q "$MOUNT_POINT" && [ ! -f "$MOUNT_POINT/app/oracle/oradata/system01.dbf" ]; then
  warn "no Oracle datafiles on $MOUNT_POINT; the Oracle resources will not come online"
fi

log "Releasing the shared volume so that VCS can own it"
if mountpoint -q "$MOUNT_POINT"; then
  fuser -km "$MOUNT_POINT" >/dev/null 2>&1 || true
  umount "$MOUNT_POINT" || die "could not unmount $MOUNT_POINT on $LAB_NODE"
fi
vgchange --activate n "$VG_NAME" >/dev/null 2>&1 || true
ssh "$PEER" "mountpoint -q '$MOUNT_POINT' && { fuser -km '$MOUNT_POINT' >/dev/null 2>&1; umount '$MOUNT_POINT'; }; vgchange --activate n '$VG_NAME' >/dev/null 2>&1; true"

# ---------------------------------------------------------------- I/O fencing
# InfoScale 7.4.2 disk-based fencing needs VxVM: the coordinator disks must be
# DMP devices in a "vxfencoorddg" disk group with coordinator=on, and Veritas
# recommends three coordination points. The LIO iSCSI LUNs emulate SCSI-3
# persistent reservations, so the DMP devices are usable for fencing. When VxVM
# is not installed (Availability-only media) the cluster is still built, just
# without fencing.
FENCING=false
# shellcheck disable=SC2086
COORD_COUNT=$(printf '%s\n' ${LAB_COORD_DISKS:-} | grep -c . || true)

if [ "$COORD_COUNT" -lt 3 ]; then
  warn "I/O fencing needs three coordinator disks, found $COORD_COUNT; continuing without fencing"
elif ! command -v vxdg >/dev/null 2>&1 || ! command -v vxfenconfig >/dev/null 2>&1; then
  warn "vxdg/vxfenconfig are missing: disk-based fencing needs InfoScale Foundation or Enterprise (VxVM)"
  info "the cluster will be created without I/O fencing (UseFence = NONE)"
else
  # shellcheck disable=SC2086
  set -- $LAB_COORD_DISKS
  if ! sg_persist --in --report-capabilities --device "$1" >/dev/null 2>&1; then
    warn "$1 does not support persistent reservations; continuing without fencing"
  else
    log "Creating the VXFEN coordinator disk group"
    vxdisk scandisks >/dev/null 2>&1 || true
    coord_names=""
    for disk in "$@"; do
      base=$(basename "$disk")
      if [ -e "/dev/vx/dmp/$base" ]; then
        coord_names="$coord_names /dev/vx/dmp/$base"
      else
        coord_names="$coord_names $base"
      fi
    done

    dg_ok=false
    if vxdg -t import vxfencoorddg >/dev/null 2>&1; then
      info "coordinator disk group already exists on the LUNs"
      vxdg deport vxfencoorddg >/dev/null 2>&1 || true
      dg_ok=true
    # shellcheck disable=SC2086
    elif vxdg init vxfencoorddg $coord_names >/dev/null 2>&1; then
      vxdg -g vxfencoorddg set coordinator=on >/dev/null 2>&1
      vxdg deport vxfencoorddg >/dev/null 2>&1 || true
      if vxdg -t import vxfencoorddg >/dev/null 2>&1; then
        vxdg deport vxfencoorddg >/dev/null 2>&1 || true
        dg_ok=true
      fi
    else
      warn "could not create vxfencoorddg; continuing without fencing"
    fi

    if [ "$dg_ok" = true ]; then
      log "Starting VXFEN on both nodes"
      echo "vxfencoorddg" > /etc/vxfendg
      cp -f /etc/vxfen.d/vxfenmode_scsi3_dmp /etc/vxfenmode
      if [ -f /etc/sysconfig/vxfen ]; then
        sed -i 's/^VXFEN_START=.*/VXFEN_START=1/; s/^VXFEN_STOP=.*/VXFEN_STOP=1/' /etc/sysconfig/vxfen
      fi
      enable_svc vxfen

      # vxfen waits for the other nodes, so start it on both and poll.
      systemctl start --no-block vxfen >/dev/null 2>&1 || true
      ssh "$PEER" 'echo vxfencoorddg > /etc/vxfendg
          cp -f /etc/vxfen.d/vxfenmode_scsi3_dmp /etc/vxfenmode
          if [ -f /etc/sysconfig/vxfen ]; then
            sed -i "s/^VXFEN_START=.*/VXFEN_START=1/; s/^VXFEN_STOP=.*/VXFEN_STOP=1/" /etc/sysconfig/vxfen
          fi
          systemctl enable vxfen >/dev/null 2>&1
          systemctl start --no-block vxfen >/dev/null 2>&1 || true' >/dev/null 2>&1 || true

      deadline=$((SECONDS + 180))
      while [ $SECONDS -lt $deadline ]; do
        if vxfenadm -d 2>/dev/null | grep -q 'Fencing Mode: SCSI3' \
           && ssh "$PEER" 'vxfenadm -d 2>/dev/null | grep -q "Fencing Mode: SCSI3"' >/dev/null 2>&1; then
          FENCING=true
          break
        fi
        sleep 5
      done
      if [ "$FENCING" = true ]; then
        info "VXFEN is running on both nodes"
        vxfenadm -d 2>/dev/null | sed 's/^/    /' || true
      else
        warn "VXFEN did not come up; falling back to an unfenced cluster"
        systemctl stop vxfen >/dev/null 2>&1 || true
        ssh "$PEER" 'systemctl stop vxfen >/dev/null 2>&1 || true'
      fi
    fi
  fi
fi

if [ "$FENCING" = true ]; then
  USEFENCE="    UseFence = SCSI3"
  info "I/O fencing enabled"
else
  USEFENCE="    UseFence = NONE"
  # Make sure vxfen does not come back at boot and surprise the cluster.
  sed -i 's/^VXFEN_START=.*/VXFEN_START=0/' /etc/sysconfig/vxfen 2>/dev/null || true
  ssh "$PEER" "sed -i 's/^VXFEN_START=.*/VXFEN_START=0/' /etc/sysconfig/vxfen 2>/dev/null || true"
  info "I/O fencing disabled for this run"
fi

log "Writing and validating main.cf"
render_main_cf() {
  sed -e "s:@CLUSTER@:$LAB_CLUSTER_NAME:g" \
      -e "s:@NODE1@:$LAB_NODE:g" \
      -e "s:@NODE2@:$LAB_PEER:g" \
      -e "s:@VG@:$VG_NAME:g" \
      -e "s:@CLIENT_NIC@:$LAB_CLIENT_NIC:g" \
      -e "s:@PEER_CLIENT_IP@:$LAB_PEER_CLIENT_IP:g" \
      -e "s:@SERVICE_IP@:$LAB_SERVICE_IP:g" \
      -e "s:@NETMASK@:$NETMASK:g" \
      -e "s:@MOUNT_POINT@:$MOUNT_POINT:g" \
      -e "s:@BLOCK_DEVICE@:$BLOCK_DEVICE:g" \
      -e "s:@ORACLE_HOME@:$ORACLE_HOME:g" \
      -e "s:@USEFENCE@:$USEFENCE:g" \
      -e "s:@SID@:$SID:g" \
      "$SCRIPT_DIR/../files/main.cf.tmpl"
}

render_main_cf > /var/tmp/main.cf
install -d -m 0755 "$VCS_CONF"
install -m 0600 /var/tmp/main.cf "$VCS_CONF/main.cf"

verify_log=$(mktemp)
if ! "$VCS_BIN/hacf" -verify "$VCS_CONF" > "$verify_log" 2>&1; then
  cat "$verify_log" >&2
  rm -f "$verify_log"
  die "hacf rejected main.cf"
fi
rm -f "$verify_log"
info "hacf -verify: OK"

log "Copying the configuration to $LAB_PEER"
ssh "$PEER" 'install -d -m 0755 /etc/VRTSvcs/conf/config'
ssh "$PEER" 'cat > /etc/VRTSvcs/conf/config/main.cf && chmod 0600 /etc/VRTSvcs/conf/config/main.cf' \
  < /var/tmp/main.cf
ssh "$PEER" 'ls -l /etc/VRTSvcs/conf/config/OracleTypes.cf >/dev/null' \
  || warn "OracleTypes.cf is missing on $LAB_PEER; the Oracle agent type may not load"

log "Starting VCS on $LAB_NODE"
enable_svc vcs
start_svc vcs

wait_for_vcs() {
  local deadline=$((SECONDS + 180))
  while [ $SECONDS -lt $deadline ]; do
    if "$VCS_BIN/hasys" -state 2>/dev/null | grep -q RUNNING; then
      return 0
    fi
    sleep 5
  done
  return 1
}
wait_for_vcs || { "$VCS_BIN/hastatus" -summary >&2 || true; die "VCS did not start on $LAB_NODE"; }

log "Starting VCS on $LAB_PEER"
ssh "$PEER" 'systemctl enable vcs >/dev/null 2>&1; systemctl start vcs 2>/dev/null || /etc/init.d/vcs start' \
  || warn "could not start VCS on $LAB_PEER"

all_nodes_running() {
  [ "$("$VCS_BIN/hasys" -state 2>/dev/null | awk -v n="$LAB_NODE" '$1 == n && $2 == "RUNNING"' | wc -l)" -eq 1 ] \
    && [ "$("$VCS_BIN/hasys" -state 2>/dev/null | awk -v n="$LAB_PEER" '$1 == n && $2 == "RUNNING"' | wc -l)" -eq 1 ]
}

deadline=$((SECONDS + 300))
until all_nodes_running; do
  if [ $SECONDS -ge $deadline ]; then
    "$VCS_BIN/hasys" -state >&2 || true
    die "both nodes did not join the cluster"
  fi
  sleep 5
done
info "both nodes are RUNNING"

log "Waiting for the ora_sg service group"
group_online() {
  "$VCS_BIN/hagrp" -state ora_sg 2>/dev/null | grep -q ONLINE
}
deadline=$((SECONDS + 300))
until group_online; do
  if [ $SECONDS -ge $deadline ]; then
    warn "ora_sg did not come online by itself, trying an explicit online"
    "$VCS_BIN/hagrp" -online ora_sg -sys "$LAB_NODE" || true
    deadline=$((SECONDS + 120))
    while ! group_online && [ $SECONDS -lt $deadline ]; do sleep 5; done
    break
  fi
  sleep 10
done

if group_online; then
  mark_done vcs_config
  log "Cluster is online"
else
  "$VCS_BIN/hastatus" -summary >&2 || true
  die "ora_sg did not come online, check 'hastatus -summary' on $LAB_NODE"
fi

"$VCS_BIN/hastatus" -summary
