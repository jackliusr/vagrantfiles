#!/usr/bin/env bash
# 03-client.sh - joins the client VM to the cluster: it takes the monitor list
# and a CephFS keyring from ceph1, mounts the file system with ceph-fuse, adds
# the matching fstab entry and proves that the mount works.
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
: "${LAB_FS_NAME:?LAB_FS_NAME is not set}"
: "${LAB_BOOTSTRAP_HOST:?LAB_BOOTSTRAP_HOST is not set}"
: "${LAB_SERVERS:?LAB_SERVERS is not set}"

[ "$LAB_ROLE" = client ] || die "03-client.sh configures a client, not a $LAB_ROLE"

# Each client has its own CephX user (client.client1, client.client2, ...), which
# 02-cluster.sh creates; the keyring name follows Ceph's convention of
# /etc/ceph/<cluster>.client.<id>.keyring.
ENTITY=$(client_entity)
KEYRING="$CEPH_CONF_DIR/ceph.$ENTITY.keyring"

cluster_up() { lab_ssh "$LAB_BOOTSTRAP_HOST" ceph -s >/dev/null 2>&1; }

log "Waiting for the cluster on $LAB_BOOTSTRAP_HOST"
wait_until 900 "a working cluster on $LAB_BOOTSTRAP_HOST" cluster_up \
  || die "no cluster to join - run ./lab cluster first"

log "Installing the cluster configuration and the CephFS keyring"
# A client needs the monitor addresses and its own key, nothing else. The file
# system's data never flows through the monitors, so no full ceph.conf is
# needed.
install -d -m 0755 "$CEPH_CONF_DIR"
lab_ssh "$LAB_BOOTSTRAP_HOST" "ceph config generate-minimal-conf" > "$CEPH_CONF_DIR/ceph.conf"
lab_ssh "$LAB_BOOTSTRAP_HOST" "ceph auth get $ENTITY" > "$KEYRING"
chmod 0644 "$CEPH_CONF_DIR/ceph.conf"
chmod 0600 "$KEYRING"
info "monitors: $(grep -E '^[[:space:]]*mon_host' "$CEPH_CONF_DIR/ceph.conf" | cut -d= -f2-)"

log "Mounting $LAB_FS_NAME on $LAB_MOUNT"
mount_cephfs "$LAB_MOUNT"

log "Adding the fstab entry"
FSTAB_BEGIN="# BEGIN ceph-lab"
FSTAB_END="# END ceph-lab"
sed -i "/^${FSTAB_BEGIN}$/,/^${FSTAB_END}$/d" /etc/fstab
{
  echo "$FSTAB_BEGIN"
  printf '%s:/ %s fuse.ceph ceph.id=%s,ceph.conf=%s/ceph.conf,_netdev,defaults 0 0\n' \
    "$(mon_list)" "$LAB_MOUNT" "${ENTITY#client.}" "$CEPH_CONF_DIR"
  echo "$FSTAB_END"
} >> /etc/fstab
# A _netdev entry is pulled in by remote-fs.target, and this box ships that
# target disabled, so nothing would mount the file system at boot.
systemctl enable remote-fs.target >/dev/null 2>&1 || warn "could not enable remote-fs.target"
systemctl daemon-reload
info "$LAB_MOUNT is mounted at boot through remote-fs.target"

log "Creating the shared scratch directory"
# The file system root is owned by root (ceph-fuse runs as root and mounts with
# allow_other), so the vagrant user can read but not create files there. A
# world-writable, sticky directory gives both clients somewhere to write
# without sudo: it is the same directory in both mounts.
install -d -m 1777 "$LAB_MOUNT/shared"
info "$LAB_MOUNT/shared is mode $(stat -c %a "$LAB_MOUNT/shared")"

log "Verifying the mount"
stat -f -c '    filesystem type %T, %S byte blocks, mounted from %n' "$LAB_MOUNT"
df -h "$LAB_MOUNT" | sed 's/^/    /'

probe="$LAB_MOUNT/hello-from-$LAB_NODE.txt"
printf 'written by %s at %s\n' "$LAB_NODE" "$(date -Is)" > "$probe"
info "wrote $probe:"
sed 's/^/    /' "$probe"
rm -f "$probe"

# The client key has no manager caps, so `ceph fs status` is refused here; the
# file system list is the most an ordinary client may ask for.
ceph -n "$ENTITY" fs ls 2>/dev/null | sed 's/^/    /' || true

save_lab_env
mark_done client
log "$LAB_MOUNT is ready on $LAB_NODE"
