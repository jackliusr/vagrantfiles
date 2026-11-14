#!/usr/bin/env bash
# 10-status.sh - prints the state of one node. Safe to run at any time, even
# before the lab is configured, for both array appliances and database hosts.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/dr-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_lab_env

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID:-orcl}

section() { printf '\n== %s\n' "$*"; }

if [ "${LAB_ROLE:-}" = "array" ]; then
  section "Array appliance $LAB_NODE (site ${LAB_SITE:-?})"
  printf '    front end %s (%s), replication %s (%s)\n' \
    "${LAB_SAN_FE_IP:-?}" "${LAB_SAN_NIC:-?}" "${LAB_REPL_IP:-?}" "${LAB_REPL_NIC:-?}"

  section "DRBD replication"
  if command -v drbdadm >/dev/null 2>&1; then
    printf '    version: %s\n' "$(awk '/^version:/ {print $2}' /proc/drbd 2>/dev/null)"
    drbdadm status 2>&1 | sed 's/^/    /'
  else
    echo "    DRBD is not installed"
  fi

  section "Replication link"
  if [ -n "${LAB_REPL_NIC:-}" ]; then
    qdisc=$(tc qdisc show dev "$LAB_REPL_NIC" 2>/dev/null | head -n 1)
    printf '    %s\n' "${qdisc:-no qdisc information}"
  fi

  section "iSCSI export"
  if command -v targetcli >/dev/null 2>&1; then
    targetcli ls /iscsi 2>/dev/null | sed 's/^/    /' | head -n 20
    printf '    portals: '
    targetcli ls "/iscsi/${LAB_ISCSI_IQN}/tpg1/portals" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | tr '\n' ' '
    echo
  else
    echo "    targetcli is not installed"
  fi
else
  section "Database host $LAB_NODE (site ${LAB_SITE:-?}, ${LAB_SITE_ROLE:-?})"
  printf '    own SAN address %s (%s), array %s, client %s (%s)\n' \
    "${LAB_DB_SAN_IP:-?}" "${LAB_SAN_NIC:-?}" "${LAB_SAN_IP:-?}" \
    "${LAB_APP_IP:-?}" "${LAB_APP_NIC:-?}"

  section "iSCSI sessions"
  iscsiadm -m session 2>&1 | sed 's/^/    /' || echo "    no session to ${LAB_SAN_IP:-unknown}"
  for lun in "${LAB_LUN0:-}" "${LAB_LUN1:-}"; do
    [ -n "$lun" ] || continue
    if [ -e "$lun" ]; then
      printf '    %s -> %s\n' "$lun" "$(readlink -f "$lun")"
    else
      printf '    %s: not present\n' "$lun"
    fi
  done

  section "Filesystems"
  for pair in "oradata:/u02" "orafra:/u03"; do
    label=${pair%%:*}
    target=${pair##*:}
    if mountpoint -q "$target"; then
      printf '    %s on %s: %s, %s free\n' "$label" "$target" \
        "$(findmnt -no SOURCE "$target")" "$(df -h --output=avail "$target" | tail -n 1 | tr -d ' ')"
    else
      printf '    %s: not mounted\n' "$target"
    fi
  done

  section "Service address $LAB_SERVICE_IP"
  if ip -4 -o addr show 2>/dev/null | grep -q " ${LAB_SERVICE_IP}/"; then
    printf '    owned by %s (active site)\n' "$LAB_NODE"
  else
    printf '    not present on %s\n' "$LAB_NODE"
  fi

  section "Oracle instance"
  if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
    printf '    the Oracle software is not installed on %s\n' "$LAB_NODE"
  elif ! pgrep -u oracle -f "ora_pmon_$SID" >/dev/null 2>&1; then
    printf '    instance %s is not running on %s\n' "$SID" "$LAB_NODE"
  else
    su - oracle -c "sqlplus -s -L / as sysdba" 2>/dev/null <<SQL | grep -vE '^$' | sed 's/^/    /'
set heading off feedback off pages 0 serveroutput on size unlimited
declare
  v_inst varchar2(200);
  v_rows number;
begin
  select 'instance ' || i.instance_name || ' on ' || i.host_name || ': ' || i.status ||
         ', database ' || d.open_mode || ', ' || d.log_mode
    into v_inst
    from v\$instance i, v\$database d;
  dbms_output.put_line(v_inst);

  -- The demo table is created by 08-oracle-database.sh; a database built by an
  -- older revision does not have it, which is not worth an ORA- error here.
  begin
    execute immediate 'select count(*) from system.dr_test' into v_rows;
    dbms_output.put_line('dr_test rows: ' || v_rows);
  exception
    when others then
      dbms_output.put_line('dr_test: no demo table in this database');
  end;
end;
/
exit
SQL
    if pgrep -u oracle -f tnslsnr >/dev/null 2>&1; then
      printf '    listener is running\n'
    else
      printf '    listener is not running\n'
    fi
  fi
fi
