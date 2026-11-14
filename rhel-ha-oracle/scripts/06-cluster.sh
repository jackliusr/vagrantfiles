#!/usr/bin/env bash
# 06-cluster.sh - creates the Pacemaker/Corosync cluster and the Oracle
# resource group.
#
# Run this on the primary node once both nodes are up and 03-05 have finished
# on both. It authenticates the nodes with pcs, sets up the cluster on the
# dedicated cluster network, enables SBD fencing with the shared LUN and adds
# the resource group in dependency order.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_CLUSTER_NAME:?LAB_CLUSTER_NAME is not set}"
: "${LAB_CLUSTER_IP:?LAB_CLUSTER_IP is not set}"
: "${LAB_PEER_CLUSTER_IP:?LAB_PEER_CLUSTER_IP is not set}"
: "${LAB_CLIENT_NIC:?LAB_CLIENT_NIC is not set}"
: "${LAB_SERVICE_IP:?LAB_SERVICE_IP is not set}"
: "${LAB_SBD_DISK:?LAB_SBD_DISK is not set, run the storage step first}"
: "${LAB_HACLUSTER_PASS:?LAB_HACLUSTER_PASS is not set}"

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID:-orcl}
# The ocf:heartbeat:oracle agent creates this monitoring user on start and
# refuses to run with the built-in default password.
MON_USER=OCFMON
MON_PASS=${LAB_OCFMON_PASSWORD:-Ocfmon123}
PEER="root@$LAB_PEER_CLIENT_IP"
GROUP=ora

if [ "$LAB_ROLE" != "primary" ]; then
  info "the cluster is created from the primary node; nothing to do on $LAB_NODE"
  exit 0
fi

# The script is intentionally re-runnable: the cluster, SBD and each resource
# are only created when they do not exist yet, so it can be executed again
# after adding the Oracle software or after a partial failure.

log "Checking that both nodes are ready"
command -v pcs >/dev/null || die "pcs is not installed on $LAB_NODE"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" true 2>/dev/null \
  || die "passwordless SSH to $LAB_PEER_CLIENT_IP is not working"
ssh "$PEER" 'command -v pcs >/dev/null' || die "pcs is not installed on $LAB_PEER"
ssh "$PEER" "test -e '$LAB_SBD_DISK'" || die "SBD device $LAB_SBD_DISK is missing on $LAB_PEER"
# A foreign VG (the one carrying the other node's system ID) is invisible to a
# plain vgs, so look at foreign volume groups too.
vgs --foreign vg_ora >/dev/null 2>&1 || die "volume group vg_ora is missing on $LAB_NODE"
ssh "$PEER" 'vgs --foreign vg_ora >/dev/null 2>&1' || die "volume group vg_ora is missing on $LAB_PEER"

if grep -qs "cluster_name:[[:space:]]*$LAB_CLUSTER_NAME" /etc/corosync/corosync.conf; then
  info "cluster $LAB_CLUSTER_NAME already configured"
else
  log "Authenticating the cluster nodes"
  pcs host auth "$LAB_NODE" "$LAB_PEER" -u hacluster -p "$LAB_HACLUSTER_PASS" >/dev/null \
    || die "pcs host auth failed"

  log "Creating the cluster $LAB_CLUSTER_NAME"
  pcs cluster setup "$LAB_CLUSTER_NAME" \
    "$LAB_NODE" addr="$LAB_CLUSTER_IP" \
    "$LAB_PEER" addr="$LAB_PEER_CLUSTER_IP" --start --enable >/dev/null \
    || die "pcs cluster setup failed"
fi

pcs cluster start --all >/dev/null || die "could not start the cluster on both nodes"
pcs cluster enable --all >/dev/null 2>&1 || warn "could not enable the cluster at boot"
pcs property set stonith-enabled=true >/dev/null
pcs quorum update wait_for_all=1 >/dev/null 2>&1 || true
# Two nodes without a quorum device: the surviving node must keep serving.
pcs property set no-quorum-policy=ignore >/dev/null
# Keep a running group where it is. Without stickiness the scheduler is free to
# put the group back on the previous node as soon as a move constraint is
# removed, which makes ./lab switch look like it failed.
pcs resource defaults resource-stickiness=100 >/dev/null 2>&1 || true

# Enabling SBD reconfigures corosync (auto_tie_breaker for two nodes), which
# pcs only allows while the cluster is stopped.
if grep -qs '^SBD_DEVICE=' /etc/sysconfig/sbd && sbd -d "$LAB_SBD_DISK" dump >/dev/null 2>&1; then
  info "SBD is already configured"
else
  log "Configuring SBD fencing on $LAB_SBD_DISK"
  pcs cluster stop --all >/dev/null 2>&1 || true
  systemctl stop sbd >/dev/null 2>&1 || true
  ssh "$PEER" 'systemctl stop sbd >/dev/null 2>&1 || true'
  # 'enable' only writes the configuration; the SBD header on the device is
  # written by 'device setup' (sbd refuses a device without a valid header).
  pcs stonith sbd device setup device="$LAB_SBD_DISK" --force >/dev/null \
    || die "could not initialise the SBD header"
  # Watchdog validation can reset the node (which would interrupt the
  # provisioning run), so skip it and rely on SBD's own checks.
  pcs stonith sbd enable device="$LAB_SBD_DISK" watchdog=/dev/watchdog \
    --no-watchdog-validation >/dev/null \
    || die "could not enable SBD"

  # Enabling SBD restarts corosync; wait until pcsd answers on both nodes
  # before touching the cluster again.
  pcsd_ready=false
  for _ in $(seq 1 60); do
    if systemctl is-active pcsd >/dev/null 2>&1 \
       && ssh "$PEER" 'systemctl is-active pcsd >/dev/null 2>&1'; then
      pcsd_ready=true
      break
    fi
    sleep 5
  done
  [ "$pcsd_ready" = true ] || die "pcsd did not come back after enabling SBD"
  pcs cluster start --all >/dev/null || die "could not restart the cluster after enabling SBD"
fi

# pcs 0.11 does not create the fence device itself when the cluster is stopped,
# and without a stonith device Pacemaker cannot fence a peer.
if ! pcs stonith config sbd 2>/dev/null | grep -q 'Resource: sbd'; then
  log "Creating the fence_sbd device"
  pcs stonith create sbd fence_sbd devices="$LAB_SBD_DISK" pcmk_delay_max=30 >/dev/null \
    || die "could not create the fence_sbd device"
fi

sbd_ok=false
for _ in $(seq 1 60); do
  if pcs stonith sbd status 2>/dev/null | grep -qi 'SBD.*ENABLED\|device.*initialized'; then
    sbd_ok=true
    break
  fi
  if systemctl is-active sbd >/dev/null 2>&1; then
    sbd_ok=true
    break
  fi
  sleep 5
done
[ "$sbd_ok" = true ] || warn "SBD does not look healthy yet, check 'pcs stonith sbd status'"
pcs stonith sbd status 2>/dev/null | sed 's/^/    /' || true

resource_exists() { pcs resource config "$1" >/dev/null 2>&1; }

create_resource() {
  local name=$1
  shift
  if resource_exists "$name"; then
    info "$name already exists"
  else
    pcs resource create "$name" "$@" --group "$GROUP" >/dev/null \
      || die "could not create $name"
    info "$name created"
  fi
}

log "Creating the $GROUP resource group"
create_resource ora_vg ocf:heartbeat:LVM-activate vgname=vg_ora vg_access_mode=system_id
create_resource ora_fs ocf:heartbeat:Filesystem \
  device=/dev/vg_ora/lv_u02 directory=/u02 fstype=ext4
create_resource ora_ip ocf:heartbeat:IPaddr2 \
  ip="$LAB_SERVICE_IP" cidr_netmask=24 nic="$LAB_CLIENT_NIC"
# LVM, filesystem and the floating IP work without Oracle, so the group is
# useful before the media is installed; the database resources are added as
# soon as the Oracle home exists on both nodes.
if [ -x "$ORACLE_HOME/bin/sqlplus" ] && ssh "$PEER" "test -x '$ORACLE_HOME/bin/sqlplus'"; then
  # The listener starts before the database so that PMON registers the service
  # with local_listener at startup instead of waiting for a later re-register.
  create_resource ora_lsnr ocf:heartbeat:oralsnr \
    sid="$SID" home="$ORACLE_HOME" user=oracle listener=LISTENER
  create_resource ora_db ocf:heartbeat:oracle \
    sid="$SID" home="$ORACLE_HOME" user=oracle \
    monuser="$MON_USER" monpassword="$MON_PASS"
else
  warn "Oracle is not installed on both nodes yet; added only ora_vg, ora_fs and ora_ip"
  info "install the Oracle media and run this step again to add ora_db and ora_lsnr"
fi

log "Waiting for the resource group"
deadline=$((SECONDS + 300))
while [ $SECONDS -lt $deadline ]; do
  if pcs resource status "$GROUP" 2>/dev/null | grep -q Started; then
    break
  fi
  sleep 10
done

pcs status --full 2>&1 | sed 's/^/    /'
if pcs resource status "$GROUP" 2>/dev/null | grep -q Started; then
  log "Cluster is running the $GROUP group"
else
  warn "the $GROUP group is not fully started yet; check 'pcs status'"
fi
