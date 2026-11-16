#!/usr/bin/env bash
# cluster-action.sh - per-node helpers used by ./lab.
#
#   start | stop | restart   the Ceph daemons on this node (ceph.target)
#   daemons                  one line per daemon unit
#   mount | umount           the CephFS mount on the client
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/ceph-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

daemons() {
  systemctl list-units --no-legend --plain --type service 'ceph-*' 2>/dev/null |
    awk '{ printf "    %-55s %s %s\n", $1, $3, $4 }'
}

case "${1:-daemons}" in
  start)
    log "Starting the Ceph daemons on $LAB_NODE"
    systemctl start ceph.target
    daemons
    ;;
  stop)
    log "Stopping the Ceph daemons on $LAB_NODE"
    systemctl stop ceph.target
    daemons
    ;;
  restart)
    log "Restarting the Ceph daemons on $LAB_NODE"
    systemctl restart ceph.target
    daemons
    ;;
  daemons)
    daemons
    ;;
  mount)
    mount_cephfs "$LAB_MOUNT"
    df -h "$LAB_MOUNT" | sed 's/^/    /'
    ;;
  umount)
    umount_cephfs "$LAB_MOUNT"
    ;;
  help | -h | --help | *)
    sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
esac
