#!/usr/bin/env bash
# 03-target.sh - defines the iSCSI target of one array.
#
# Each site gets its own IQN and its own portal address, so the database host at
# site A and the one at site B log into different arrays: there is no shared
# fabric between the data centres, exactly like two separate SANs. The LUNs
# themselves are presented by dr-action.sh (present-luns / unpresent-luns),
# because DRBD can only hand out writable devices from the site that is
# currently Primary.
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
: "${LAB_SAN_FE_IP:?LAB_SAN_FE_IP is not set}"
: "${LAB_ISCSI_IQN:?LAB_ISCSI_IQN is not set}"
: "${LAB_DB_HOST_IP:?LAB_DB_HOST_IP is not set}"

command -v targetcli >/dev/null || die "targetcli is not installed, run 01-array.sh first"

log "Configuring $LAB_ISCSI_IQN on $LAB_SAN_FE_IP"

if targetcli ls /iscsi 2>/dev/null | grep -qw "$LAB_ISCSI_IQN"; then
  info "target $LAB_ISCSI_IQN already exists"
else
  targetcli /iscsi create "$LAB_ISCSI_IQN" >/dev/null || die "could not create the target"
  info "target $LAB_ISCSI_IQN created"
fi

# Only answer on the array's own front-end address: the default 0.0.0.0 portal
# would also listen on the management and replication networks.
if ! targetcli ls "/iscsi/$LAB_ISCSI_IQN/tpg1/portals" 2>/dev/null | grep -q "$LAB_SAN_FE_IP"; then
  targetcli "/iscsi/$LAB_ISCSI_IQN/tpg1/portals" delete 0.0.0.0 3260 >/dev/null 2>&1 || true
  targetcli "/iscsi/$LAB_ISCSI_IQN/tpg1/portals" create "$LAB_SAN_FE_IP" >/dev/null \
    || die "could not create the $LAB_SAN_FE_IP portal"
  info "portal $LAB_SAN_FE_IP:3260 created"
fi

# No CHAP, no initiator ACLs: any host that reaches this fabric may log in. That
# keeps the lab usable but is the first thing to change for anything real.
targetcli "/iscsi/$LAB_ISCSI_IQN/tpg1" set attribute \
  authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1 \
  >/dev/null || warn "could not set the tpg attributes"
info "initiator $LAB_DB_HOST_IP may log in as demo mode (no ACL, no CHAP)"

targetcli saveconfig >/dev/null || die "could not save the target configuration"
info "configuration saved to /etc/target/saveconfig.json"

# The block backstores point at /dev/drbdN, so the target has to be restored
# after DRBD brought its resources up.
install -d -m 0755 /etc/systemd/system/target.service.d
cat > /etc/systemd/system/target.service.d/10-after-drbd.conf <<'EOF'
# Written by 03-target.sh: the LUNs are DRBD devices and must exist first.
[Unit]
After=drbd.service
Wants=drbd.service

[Service]
ExecStartPre=-/usr/sbin/drbdadm up --all
EOF
systemctl daemon-reload
systemctl enable target.service >/dev/null 2>&1 || warn "could not enable target.service"
systemctl restart target.service >/dev/null 2>&1 || warn "target.service did not restart cleanly"

log "iSCSI target on $LAB_NODE"
targetcli ls "/iscsi/$LAB_ISCSI_IQN/tpg1" 2>/dev/null | sed 's/^/    /'

if [ "$(drbdadm role ora_data 2>/dev/null)" = "Primary" ]; then
  log "This array owns the data, presenting the LUNs"
  bash "$SCRIPT_DIR/dr-action.sh" present-luns
else
  info "this array is a replication target: no LUNs are presented until it is promoted"
fi

save_lab_env
mark_done target
log "Array $LAB_NODE is serving iSCSI as $LAB_ISCSI_IQN"
