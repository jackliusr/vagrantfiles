#!/usr/bin/env bash
# 02-cluster.sh - runs on ceph1 and grows three prepared VMs into a Ceph
# cluster: cephadm bootstrap, three monitors, two managers, an OSD on every
# spare disk, and a CephFS file system with an active/standby MDS pair plus a
# keyring for the client VM.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/ceph-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_IP:?LAB_IP is not set}"
: "${LAB_FS_NAME:?LAB_FS_NAME is not set}"
: "${LAB_BOOTSTRAP_HOST:?LAB_BOOTSTRAP_HOST is not set}"
: "${LAB_PUBLIC_NETWORK:?LAB_PUBLIC_NETWORK is not set}"
: "${LAB_DASHBOARD_PASSWORD:?LAB_DASHBOARD_PASSWORD is not set}"
: "${LAB_SERVERS:?LAB_SERVERS is not set}"
: "${LAB_CLIENTS:?LAB_CLIENTS is not set}"

[ "$LAB_ROLE" = server ] || die "02-cluster.sh configures a Ceph server, not a $LAB_ROLE"
[ "$LAB_NODE" = "$LAB_BOOTSTRAP_HOST" ] \
  || die "run the cluster step on $LAB_BOOTSTRAP_HOST (./lab cluster)"

server_count=$(server_names | wc -l)
expected_osds=$(( LAB_OSD_DISKS * server_count ))

host_in_cluster() {
  ceph orch host ls --format json |
    grep -qE "\"hostname\":[[:space:]]*\"$1\""
}

hosts_online() {
  local count
  count=$(ceph orch host ls --format json | python3 -c '
import json, sys
print(sum(1 for h in json.load(sys.stdin) if not h.get("status")))')
  [ "$count" -ge "$server_count" ]
}

mon_quorum_ok() { [ "$(mon_quorum)" -ge "$server_count" ]; }

osds_ready() {
  local up total
  read -r up total < <(ceph osd stat --format json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["num_up_osds"], d["num_osds"])')
  [ "$up" -ge "$expected_osds" ] && [ "$total" -ge "$expected_osds" ]
}

mds_active() { ceph mds stat 2>/dev/null | grep -q 'up:active'; }

if [ -f "$CEPH_CONF_DIR/ceph.conf" ] && ceph_ready; then
  info "$LAB_CLUSTER_NAME is already bootstrapped on $LAB_NODE"
else
  log "Bootstrapping $LAB_CLUSTER_NAME on $LAB_NODE"
  info "the first run pulls the Ceph container image on every node (5-20 min)"
  image_args=()
  [ -n "${LAB_IMAGE:-}" ] && image_args=(--image "$LAB_IMAGE")
  cephadm bootstrap \
    --mon-ip "$LAB_IP" \
    --skip-monitoring-stack \
    --skip-firewalld \
    --allow-fqdn-hostname \
    --initial-dashboard-user admin \
    --initial-dashboard-password "$LAB_DASHBOARD_PASSWORD" \
    "${image_args[@]}" \
    || die "cephadm bootstrap failed; see /var/log/ceph/cephadm.log on $LAB_NODE"
fi

wait_until 300 "the first monitor to answer" ceph_ready \
  || die "ceph -s does not work on $LAB_NODE"

log "Telling Ceph which network the daemons live on"
ceph config set mon public_network "$LAB_PUBLIC_NETWORK/24"
# The orchestrator caches what it knows about the hosts for ten minutes by
# default, which makes ./lab status lie for a while after every change.
ceph config set mgr mgr/cephadm/daemon_cache_timeout 60
ceph mgr module enable volumes >/dev/null 2>&1

log "Adding the other servers"
# cephadm does not use the lab key: it installs its own public key on every host
# it manages, and that is what makes the managers able to deploy daemons.
cephadm_pub=$(cat "$CEPH_CONF_DIR/ceph.pub")
for spec in $(lab_nodes); do
  name=${spec%%:*}
  [ "$name" = "$LAB_NODE" ] && continue
  lab_ssh "$name" "install -d -m 0700 /root/.ssh
    touch /root/.ssh/authorized_keys
    grep -qxF '$cephadm_pub' /root/.ssh/authorized_keys || echo '$cephadm_pub' >> /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys" \
    || die "could not install the cephadm public key on $name"
  info "$name trusts the cephadm key"
done

# _admin makes cephadm copy ceph.conf and the admin keyring to the host, which
# is what lets every server answer `ceph -s` on its own.
ceph orch host label add "$LAB_NODE" _admin >/dev/null 2>&1 || true
for spec in $(lab_nodes); do
  name=${spec%%:*}
  ip=${spec#*:}
  if host_in_cluster "$name"; then
    info "$name is already a cluster host"
  else
    ceph orch host add "$name" "$ip" --labels _admin \
      || die "could not add $name to the cluster"
    info "$name added ($ip)"
  fi
done

wait_until 300 "all cluster hosts to become reachable" hosts_online \
  || die "cephadm cannot reach every host - check the cephadm key and sshd"
ceph orch host ls

log "Spreading the monitors over the servers"
mon_placement=$(server_names | paste -sd, -)
ceph orch apply mon --placement="$mon_placement"
wait_until 600 "three monitors in quorum" mon_quorum_ok \
  || warn "the monitors did not all reach quorum - continue watching with ./lab status"

log "Placing two managers (active and standby)"
ceph orch apply mgr --placement="2 $(server_names | paste -sd' ' -)"

log "Showing the disks cephadm found"
ceph orch device ls --wide

log "Creating one OSD per available disk"
info "expecting $expected_osds OSDs ($LAB_OSD_DISKS disks on each of $server_count servers)"
ceph orch apply osd --all-available-devices
wait_until 1800 "$expected_osds OSDs up" osds_ready \
  || warn "not every OSD came up; ./lab status shows the current state"

log "Creating the $LAB_FS_NAME file system"
if ceph fs ls --format json | grep -qE "\"name\":[[:space:]]*\"$LAB_FS_NAME\""; then
  info "$LAB_FS_NAME already exists"
else
  # CephFS keeps the namespace (the directory tree and the file metadata) in a
  # metadata pool and the file contents in a data pool. They are separate so
  # each can be sized and tuned on its own.
  ceph osd pool create "${LAB_FS_NAME}_metadata"
  ceph osd pool create "${LAB_FS_NAME}_data"
  ceph osd pool application enable "${LAB_FS_NAME}_metadata" cephfs
  ceph osd pool application enable "${LAB_FS_NAME}_data" cephfs
  ceph fs new "$LAB_FS_NAME" "${LAB_FS_NAME}_metadata" "${LAB_FS_NAME}_data"
  # The bulk flag tells the autoscaler that this pool is expected to hold a lot
  # of data, which is what a CephFS data pool does.
  ceph osd pool set "${LAB_FS_NAME}_data" bulk true
fi

log "Deploying an active and a standby MDS"
# Two daemons on different hosts: one serves the file system, the other takes
# over within seconds if the first one goes away.
ceph orch apply mds "$LAB_FS_NAME" --placement="2 $(server_names | paste -sd' ' -)"
wait_until 900 "an MDS to become active" mds_active \
  || warn "no MDS is active yet; ceph fs status shows why"
ceph mds stat

log "Waiting for the file system to settle"
wait_until 300 "every placement group to be active+clean" pgs_clean \
  || info "the placement groups are still moving; ./lab status shows the rest"

log "Authorising one CephX user per client node"
# rwps = read, write, layout and snapshot rights on the whole tree. The snapshot
# right is what lets a client create .snap directories; without it the snapshot
# part of ./lab demo fails with EACCES. Both clients get the same caps but a
# separate identity, so they show up as two clients in `ceph fs status`.
for spec in $(client_nodes); do
  name=${spec%%:*}
  ceph fs authorize "$LAB_FS_NAME" "$(client_entity "$name")" / rwps >/dev/null 2>&1
  info "client.$name may read, write and snapshot the whole $LAB_FS_NAME tree"
done

log "Cluster ready"
ceph -s
printf '\n'
info "dashboard   https://$LAB_IP:8443 (admin / $LAB_DASHBOARD_PASSWORD)"
info "file system $LAB_FS_NAME on $(server_names | paste -sd, -)"
info "next        ./lab client"

save_lab_env
mark_done cluster
