#!/usr/bin/env bash
# 07-status.sh - prints the state of the lab. Safe to run at any time, even
# before the cluster or Oracle are installed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_lab_env

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID:-orcl}
GROUP=ora

section() { printf '\n== %s\n' "$*"; }

section "Node $LAB_NODE ($LAB_ROLE), peer $LAB_PEER"
printf '    cluster %s (%s), client %s (%s)\n' \
  "$LAB_CLUSTER_IP" "${LAB_CLUSTER_NIC:-?}" \
  "$LAB_CLIENT_IP" "${LAB_CLIENT_NIC:-?}"

section "iSCSI sessions"
iscsiadm -m session 2>&1 | sed 's/^/    /' || echo "    no session to ${LAB_STORAGE_IP:-unknown}"
printf '    data disk: %s\n' "${LAB_DATA_DISK:-not discovered}"
printf '    sbd disk:  %s\n' "${LAB_SBD_DISK:-not discovered}"

section "Shared volume"
vgs vg_ora 2>/dev/null | sed 's/^/    /' || echo "    volume group vg_ora not visible"
lvs vg_ora 2>/dev/null | sed 's/^/    /'
if mountpoint -q /u02; then
  echo "    /u02 is mounted on this node"
else
  echo "    /u02 is not mounted on this node"
fi

if ! command -v pcs >/dev/null 2>&1; then
  section "Cluster"
  echo "    pcs is not installed"
  exit 0
fi

section "Cluster status"
pcs status 2>&1 | sed 's/^/    /'

section "Quorum"
corosync-quorumtool -s 2>&1 | sed 's/^/    /'

section "SBD fencing"
pcs stonith sbd status 2>&1 | sed 's/^/    /'

section "Resource group $GROUP"
pcs resource status "$GROUP" 2>&1 | sed 's/^/    /'

section "Service IP $LAB_SERVICE_IP"
if ping -c 1 -W 2 "$LAB_SERVICE_IP" >/dev/null 2>&1; then
  echo "    reachable"
else
  echo "    not reachable from $LAB_NODE"
fi

section "Oracle instance"
if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
  echo "    the Oracle software is not installed on $LAB_NODE"
elif ! pgrep -u oracle -f "ora_pmon_$SID" >/dev/null 2>&1; then
  # Only one node runs the instance; on the other one sqlplus would fail with
  # ORA-01034, which says nothing useful about the lab.
  active_node=$(crm_resource --resource ora_db --locate 2>/dev/null \
    | awk '/is running on/ {print $NF}')
  if [ -n "$active_node" ]; then
    echo "    instance $SID is not running on $LAB_NODE (it is active on $active_node)"
  else
    echo "    instance $SID is not running on $LAB_NODE"
  fi
else
  state=$(su - oracle -c "sqlplus -s -L / as sysdba" 2>&1 <<SQL
set heading off feedback off pages 0
select status || ' / ' || database_status from v\$instance;
exit
SQL
  )
  state=$(printf '%s\n' "$state" \
    | grep -vE '^(ORA-|Process ID|Session ID|SP2-|ERROR at line|select |\*$)' \
    | grep -v '^[[:space:]]*$' | head -n 1)
  echo "    instance $SID: ${state:-sqlplus gave no answer}"
  if pgrep -u oracle -f tnslsnr >/dev/null 2>&1; then
    echo "    listener is running"
  else
    echo "    listener is not running"
  fi
fi
