#!/usr/bin/env bash
# 07-status.sh - prints the state of one RAC node. Safe to run at any time,
# including before Grid Infrastructure is installed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/rac-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_lab_env

GRID_HOME=/u01/app/19.0.0/grid
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1

section() { printf '\n== %s\n' "$*"; }

section "Node $LAB_NODE (node $LAB_NODE_NUMBER of $LAB_CLUSTER_NAME), peer $LAB_PEER"
printf '    public %s (%s), VIP %s\n' "${LAB_PUB_IP:-?}" "${LAB_PUB_NIC:-?}" "${LAB_VIP:-?}"
printf '    private %s (%s), storage %s (%s)\n' \
  "${LAB_PRIV_IP:-?}" "${LAB_PRIV_NIC:-?}" "${LAB_STORAGE_NODE_IP:-?}" "${LAB_STORAGE_NIC:-?}"

section "Name resolution"
scan_name=${LAB_SCAN_NAME:-rac-scan}
if getent hosts "$scan_name" >/dev/null 2>&1; then
  printf '    SCAN %s: %s\n' "$scan_name" "$(getent hosts "$scan_name" | awk '{print $1}' | tr '\n' ' ')"
else
  printf '    SCAN %s does not resolve (start it on the host: sudo ./host/scan-dns.sh setup)\n' "$scan_name"
fi
printf '    %s -> %s\n' "${LAB_NODE:-?}" "$(getent ahostsv4 "${LAB_NODE:-none}" | awk 'NR == 1 {print $1}')"

section "iSCSI and ASM devices"
iscsiadm -m session 2>&1 | sed 's/^/    /' || echo "    no iSCSI session to ${LAB_STORAGE_IP:-unknown}"
for n in 1 2 3 4 5; do
  dev=/dev/asm-disk$n
  if [ -e "$dev" ]; then
    printf '    %-16s -> %-10s %s %s\n' "$dev" "$(readlink -f "$dev")" \
      "$(stat -Lc '%U:%G' "$dev")" "$(stat -Lc '%a' "$dev")"
  else
    printf '    %-16s missing\n' "$dev"
  fi
done

if [ ! -x "$GRID_HOME/bin/crsctl" ]; then
  section "Grid Infrastructure"
  printf '    not installed (no %s/bin/crsctl)\n' "$GRID_HOME"
  printf '    add LINUX.X64_193000_grid_home.zip to software/ and run ./lab grid\n'
  exit 0
fi

section "Grid Infrastructure"
su - grid -c "$GRID_HOME/bin/crsctl check cluster" 2>&1 | sed 's/^/    /'
su - grid -c "$GRID_HOME/bin/crsctl stat res -t" 2>&1 | sed -n '1,28p' | sed 's/^/    /'

section "Clusterware processes"
for proc in cssd crsd evmd; do
  if pgrep -f "bin/$proc" >/dev/null 2>&1; then
    printf '    %-6s running\n' "$proc"
  else
    printf '    %-6s not running\n' "$proc"
  fi
done

section "ASM disk groups"
if su - grid -c "export ORACLE_SID=+ASM${LAB_NODE_NUMBER}; $GRID_HOME/bin/asmcmd lsdg" >/tmp/lsdg.$$ 2>&1; then
  sed 's/^/    /' /tmp/lsdg.$$
else
  printf '    +ASM%s is not running on this node\n' "$LAB_NODE_NUMBER"
fi
rm -f /tmp/lsdg.$$

section "Database"
if [ ! -x "$ORACLE_HOME/bin/srvctl" ]; then
  printf '    the database home is not installed on %s\n' "$LAB_NODE"
  exit 0
fi
db=${LAB_DB_NAME:-ORCL}
su - oracle -c "$ORACLE_HOME/bin/srvctl status database -d $db" 2>&1 | sed 's/^/    /'
if pgrep -u oracle -f "ora_pmon_${db}" >/dev/null 2>&1; then
  # In a policy-managed database the instance names do not line up with the
  # node numbers (ORCL_1 can live on rac2), so ask srvctl which instance is
  # local instead of guessing ORCL<node-number>.
  local_inst=$(su - oracle -c "$ORACLE_HOME/bin/srvctl status database -d $db" \
    | awk -v h="$(hostname -s)" '$0 ~ h { print $2; exit }')
  [ -n "$local_inst" ] || local_inst=${db}_${LAB_NODE_NUMBER}
  printf '\n    instance on this node (%s):\n' "$local_inst"
  su - oracle -c "export ORACLE_SID=$local_inst; sqlplus -s -L / as sysdba" 2>/dev/null <<SQL | grep -vE '^$' | sed 's/^/      /'
set heading off feedback off pages 0
select 'instance ' || i.instance_name || ' on ' || i.host_name || ': ' || i.status ||
       ', database ' || d.open_mode || ', ' || d.log_mode || ', ' ||
       (select value from v\$parameter where name = 'cluster_database') || ' (cluster_database)'
  from v\$instance i, v\$database d;
exit
SQL
else
  printf '\n    no instance of %s is running on %s\n' "$db" "$LAB_NODE"
fi
