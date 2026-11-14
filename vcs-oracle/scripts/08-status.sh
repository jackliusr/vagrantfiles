#!/usr/bin/env bash
# 08-status.sh - prints the state of the lab. Safe to run at any time, even
# before VCS or Oracle are installed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_lab_env

VCS_BIN=/opt/VRTSvcs/bin
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID:-orcl}

section() { printf '\n== %s\n' "$*"; }

section "Node $LAB_NODE ($LAB_ROLE), peer $LAB_PEER"
printf '    client %s (%s), LLT %s (%s), %s (%s)\n' \
  "$LAB_CLIENT_IP" "${LAB_CLIENT_NIC:-?}" \
  "$LAB_LLT1_IP" "${LAB_LLT1_NIC:-?}" \
  "$LAB_LLT2_IP" "${LAB_LLT2_NIC:-?}"

section "iSCSI sessions"
iscsiadm -m session 2>&1 | sed 's/^/    /' || echo "    no session to ${LAB_STORAGE_IP:-unknown}"
printf '    data disk:      %s\n' "${LAB_DATA_DISK:-not discovered}"
printf '    coordinators:  %s\n' "${LAB_COORD_DISKS:-not discovered}"

section "Shared volume"
vgs vg_ora 2>/dev/null | sed 's/^/    /' || echo "    volume group vg_ora not visible"
lvs vg_ora 2>/dev/null | sed 's/^/    /'
if mountpoint -q /u02; then
  echo "    /u02 is mounted on this node"
else
  echo "    /u02 is not mounted on this node"
fi

if command -v vxfenconfig >/dev/null 2>&1; then
  section "I/O fencing"
  vxfenconfig -a 2>&1 | sed 's/^/    /'
  systemctl is-active vxfen 2>&1 | sed 's/^/    vxfen: /'
fi

if [ ! -x "$VCS_BIN/hastatus" ]; then
  section "VCS"
  echo "    VCS is not installed yet (see README.md, section 'Installing the Veritas media')"
  exit 0
fi

section "LLT"
lltstat -n 2>&1 | sed 's/^/    /'

section "GAB"
gabconfig -a 2>&1 | sed 's/^/    /'

section "Cluster"
"$VCS_BIN/hasys" -state 2>&1 | sed 's/^/    /'
"$VCS_BIN/haclus" -display UseFence 2>&1 | sed 's/^/    /'

section "Service group ora_sg"
"$VCS_BIN/hagrp" -state ora_sg 2>&1 | sed 's/^/    /'
"$VCS_BIN/hares" -state ora_sg 2>&1 | sed 's/^/    /'

section "Service IP $LAB_SERVICE_IP"
if ping -c 1 -W 2 "$LAB_SERVICE_IP" >/dev/null 2>&1; then
  echo "    reachable"
else
  echo "    not reachable from $LAB_NODE"
fi

section "Oracle instance"
if [ -x "$ORACLE_HOME/bin/sqlplus" ] && "$VCS_BIN/hagrp" -state ora_sg 2>/dev/null | grep -q ONLINE; then
  state=$(su - oracle -c "sqlplus -s -L / as sysdba" 2>/dev/null <<SQL
set heading off feedback off pages 0
select status || ' / ' || database_status from v\$instance;
exit
SQL
)
  echo "    ${state:-no answer from sqlplus}"
  if pgrep -u oracle -f tnslsnr >/dev/null 2>&1; then
    echo "    listener is running"
  else
    echo "    listener is not running"
  fi
else
  echo "    group is offline here or the Oracle software is not installed"
fi
