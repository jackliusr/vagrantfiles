#!/usr/bin/env bash
# cluster-action.sh - start/stop helpers for the cluster pieces, used by ./lab.
#
#   start-grid | stop-grid     the whole clusterware stack
#   start-db   | stop-db       the RAC database on all nodes
#   status                     one-line state of crs, ASM and the database
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/rac-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

GRID_HOME=/u01/app/19.0.0/grid
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
DB=${LAB_DB_NAME:-ORCL}

need_grid() {
  [ -x "$GRID_HOME/bin/crsctl" ] || die "Grid Infrastructure is not installed yet (./lab grid)"
}

case "${1:-status}" in
  start-grid)
    need_grid
    log "Starting the clusterware on $LAB_NODE"
    su - grid -c "$GRID_HOME/bin/crsctl start crs" 2>&1 | sed 's/^/    /'
    wait_until 300 "crsd to report ready" \
      su - grid -c "test \"\$($GRID_HOME/bin/crsctl check crs 2>/dev/null | grep -c 'is online')\" -ge 3" \
      || warn "the clusterware did not report ready in time"
    su - grid -c "$GRID_HOME/bin/crsctl check crs" 2>&1 | sed 's/^/    /'
    ;;
  stop-grid)
    need_grid
    log "Stopping the clusterware on $LAB_NODE"
    # Without -all this node waits for the other one to leave, which never
    # happens in a lab shutdown, so the stack is stopped as a whole.
    su - grid -c "$GRID_HOME/bin/crsctl stop cluster -all" 2>&1 | sed 's/^/    /' || \
      su - grid -c "$GRID_HOME/bin/crsctl stop crs -f" 2>&1 | sed 's/^/    /'
    ;;
  start-db)
    need_grid
    [ -x "$ORACLE_HOME/bin/srvctl" ] || die "the database home is not installed yet (./lab db-software)"
    log "Starting the RAC database $DB"
    su - oracle -c "$ORACLE_HOME/bin/srvctl start database -d $DB" 2>&1 | sed 's/^/    /'
    su - oracle -c "$ORACLE_HOME/bin/srvctl status database -d $DB" 2>&1 | sed 's/^/    /'
    ;;
  stop-db)
    need_grid
    log "Stopping the RAC database $DB"
    su - oracle -c "export ORACLE_SID=${DB}\$(hostname -s | tr -dc '0-9'); \
      sqlplus -s -L / as sysdba" <<'SQL' 2>/dev/null | sed 's/^/    /' || true
shutdown immediate
exit
SQL
    su - oracle -c "$ORACLE_HOME/bin/srvctl stop database -d $DB" 2>&1 | sed 's/^/    /' || true
    ;;
  status)
    printf '== Node %s\n' "$LAB_NODE"
    if [ -x "$GRID_HOME/bin/crsctl" ]; then
      su - grid -c "$GRID_HOME/bin/crsctl check crs" 2>&1 | sed 's/^/    /'
      su - oracle -c "$ORACLE_HOME/bin/srvctl status database -d $DB" 2>&1 | sed 's/^/    /' || true
    else
      printf '    Grid Infrastructure is not installed\n'
    fi
    ;;
  help | -h | --help | *)
    sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
esac
