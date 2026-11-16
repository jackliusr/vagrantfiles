#!/usr/bin/env bash
# 04-status.sh - prints the state of one lab node. Safe to run at any time,
# including before the cluster exists.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/ceph-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_lab_env

section() { printf '\n== %s\n' "$*"; }

# shellcheck disable=SC2153  # LAB_ROLE comes from /etc/ceph-lab/lab.env.
section "$LAB_NODE ($LAB_ROLE) - ${LAB_CLUSTER_NAME:-ceph-lab}"
printf '    address %s, lab network %s/24\n' "${LAB_IP:-?}" "${LAB_PUBLIC_NETWORK:-?}"
printf '    hostname -f: %s\n' "$(hostname -f 2>/dev/null || echo unknown)"
if getent hosts "$LAB_BOOTSTRAP_HOST" >/dev/null 2>&1; then
  if [ "${LAB_ROLE:-}" = server ]; then
    printf '    %s resolves, cephadm %s\n' "$LAB_BOOTSTRAP_HOST" \
      "$(cephadm version 2>/dev/null | awk '/^cephadm version/ { print $3 }' || true)"
  else
    printf '    %s resolves\n' "$LAB_BOOTSTRAP_HOST"
  fi
else
  printf '    %s does not resolve (run the base step)\n' "$LAB_BOOTSTRAP_HOST"
fi

if [ "${LAB_ROLE:-}" = client ]; then
  section "CephFS client"
  if [ -r "$CEPH_CONF_DIR/ceph.conf" ]; then
    printf '    mon_host %s\n' "$(grep -E '^[[:space:]]*mon_host' "$CEPH_CONF_DIR/ceph.conf" | cut -d= -f2-)"
  else
    printf '    no %s/ceph.conf yet (./lab client)\n' "$CEPH_CONF_DIR"
  fi
  if mountpoint -q "$LAB_MOUNT"; then
    printf '    %s mounted from %s\n' "$LAB_MOUNT" "$(mon_list)"
    stat -f -c '    %S byte blocks, %a blocks free, type %T' "$LAB_MOUNT"
    df -h "$LAB_MOUNT" | sed 's/^/    /'
  else
    printf '    %s is not mounted\n' "$LAB_MOUNT"
  fi
  section "CephFS status as seen by the client"
  # client.cephfs can read the cluster state but not use the manager, so this is
  # `ceph -s` and `ceph fs ls` rather than `ceph fs status`.
  entity=$(client_entity)
  if ceph -n "$entity" -s >/dev/null 2>&1; then
    printf '    connecting as %s\n' "$entity"
    ceph -n "$entity" -s | sed -n '1,11p' | sed 's/^/    /'
    ceph -n "$entity" fs ls | sed 's/^/    /'
  else
    printf '    no answer for %s (./lab client)\n' "$entity"
  fi
  exit 0
fi

section "Ceph daemons on this node"
if systemctl list-units --no-legend --plain 'ceph-*' 2>/dev/null | grep -q .; then
  systemctl list-units --no-legend --plain --type service 'ceph-*' 2>/dev/null |
    awk '{ printf "    %-55s %s %s\n", $1, $3, $4 }'
else
  printf '    no ceph-* systemd units (the cluster step has not run here)\n'
fi

section "Disks"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | sed 's/^/    /'

if ! ceph_ready; then
  section "Cluster"
  printf '    %s/etc/ceph/ceph.conf is not usable here\n' "$CEPH_CONF_DIR"
  printf '    run ./lab cluster (on %s) first\n' "${LAB_BOOTSTRAP_HOST:-ceph1}"
  exit 0
fi

section "Cluster health"
ceph -s | sed 's/^/    /'

section "Cluster hosts and daemons"
ceph orch host ls | sed 's/^/    /'
printf '\n'
ceph orch ps | sed 's/^/    /'

section "CephFS"
ceph fs status "$LAB_FS_NAME" 2>&1 | sed 's/^/    /'
ceph fs ls 2>&1 | sed 's/^/    /'

section "OSDs"
ceph osd tree | sed 's/^/    /'

section "Capacity"
ceph df | sed 's/^/    /'
