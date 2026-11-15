#!/usr/bin/env bash
# 06-db-create.sh - creates the RAC database with dbca.
#
# policy AUTOMATIC lets the database manage its own instances with a server pool
# instead of the administrator assigning one instance per node, which is how RAC
# databases are normally built now. The data files go to +DATA and the archive
# logs / backups to +FRA, both on ASM.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/rac-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_DB_NAME:?LAB_DB_NAME is not set}"
: "${LAB_DB_PASSWORD:?LAB_DB_PASSWORD is not set}"

GRID_HOME=/u01/app/19.0.0/grid
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_DB_NAME}
LOG=/var/tmp/dbca.log

if [ ! -x "$ORACLE_HOME/bin/dbca" ]; then
  warn "the database home is not installed yet"
  info "install it first: ./lab db-software"
  exit 0
fi
if [ ! -x "$GRID_HOME/bin/crsctl" ]; then
  warn "Grid Infrastructure is not installed yet"
  exit 0
fi
if [ "$LAB_NODE_NUMBER" != "1" ]; then
  info "the database is created from node 1 only; nothing to do on $LAB_NODE"
  exit 0
fi

if su - oracle -c "export ORACLE_SID=$SID; $ORACLE_HOME/bin/srvctl config database -d $SID" >/dev/null 2>&1; then
  info "database $SID is already registered in the cluster"
  exit 0
fi

if ! su - grid -c "export ORACLE_SID=+ASM1; $GRID_HOME/bin/asmcmd lsdg DATA" >/dev/null 2>&1; then
  die "the DATA disk group does not exist - run ./lab asm first"
fi

log "Creating the RAC database $SID on +DATA / +FRA (policy managed)"
# -totalMemory is not used for RAC: a policy-managed database gets an explicit
# SGA and PGA so that the instance sizing is predictable on both nodes.
cat > /var/tmp/create_db.sh <<EOF2
#!/bin/bash
set -e
# 19c base does not know Oracle Linux 8.9, so distid detection returns null and
# dbca's SSH/storage validation crashes with a NullPointerException. The same
# OEL8 hint used for gridSetup and runInstaller pins the distribution ID.
export CV_ASSUME_DISTID=OEL8
dbca -silent -createDatabase \\
  -templateName General_Purpose.dbc \\
  -gdbName $SID -sid $SID \\
  -createAsContainerDatabase false \\
  -sysPassword $LAB_DB_PASSWORD -systemPassword $LAB_DB_PASSWORD \\
  -databaseType MULTIPURPOSE \\
  -storageType ASM \\
  -diskGroupName DATA \\
  -recoveryGroupName FRA \\
  -datafileDestination +DATA \\
  -recoveryAreaDestination +FRA \\
  -recoveryAreaSize 4096 \\
  -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \\
  -initParams "sga_target=1536M,pga_aggregate_target=512M,db_time_zone=UTC" \\
  -emConfiguration NONE \\
  -redoLogFileSize 100 \\
  -sampleSchema false \\
  -policyManaged \\
  -serverPoolName ${SID}Pool \\
  -createServerPool
EOF2
chmod 0755 /var/tmp/create_db.sh

if ! su - oracle -c /var/tmp/create_db.sh > "$LOG" 2>&1; then
  if su - oracle -c "export ORACLE_SID=$SID; $ORACLE_HOME/bin/srvctl config database -d $SID" >/dev/null 2>&1; then
    warn "dbca returned an error but the database is registered (see $LOG)"
  else
    tail -n 40 "$LOG" >&2
    die "dbca failed, see $LOG"
  fi
fi

log "Enabling archivelog mode and a demo table"
# Archiving is a whole-database change, so the instances are stopped through
# srvctl, the database is mounted on one instance, switched and opened again.
# In a policy-managed database the instance names do not necessarily line up
# with the node numbers (ORCL_1 may live on rac2), so the local instance is
# looked up rather than guessed.
su - oracle -c "$ORACLE_HOME/bin/srvctl stop database -d $SID" >/dev/null 2>&1 || true
su - oracle -c "$ORACLE_HOME/bin/srvctl start database -d $SID -o mount" > /var/tmp/rac_mount.log 2>&1 \
  || { tail -n 20 /var/tmp/rac_mount.log >&2; die "could not mount the database through srvctl"; }

local_inst=$(su - oracle -c "$ORACLE_HOME/bin/srvctl status database -d $SID" \
  | awk -v h="$(hostname -s)" '$0 ~ h { print $2; exit }')
[ -n "$local_inst" ] || local_inst=${SID}_${LAB_NODE_NUMBER}
info "local instance on $LAB_NODE is $local_inst"

cat > /var/tmp/rac_arch.sql <<'SQL'
whenever sqlerror exit failure
alter database archivelog;
alter database open;
-- sqlplus / as sysdba connects as SYS; put the demo table where the
-- ./lab sql helper (which logs in as SYSTEM) can see it.
alter session set current_schema = system;
create table rac_test (
  id   number generated always as identity,
  ts   timestamp default systimestamp,
  inst varchar2(16),
  note varchar2(60)
);
insert into rac_test (inst, note) values (sys_context('USERENV','INSTANCE_NAME'),
  'row inserted by the database creation step');
commit;
exit
SQL
chown oracle:oinstall /var/tmp/rac_arch.sql
su - oracle -c "export ORACLE_SID=$local_inst; sqlplus -s -L / as sysdba @/var/tmp/rac_arch.sql" \
  > /var/tmp/rac_arch.log 2>&1 \
  || { tail -n 20 /var/tmp/rac_arch.log >&2; warn "could not switch to archivelog mode"; }

su - oracle -c "$ORACLE_HOME/bin/srvctl stop database -d $SID" >/dev/null 2>&1 || true
su - oracle -c "$ORACLE_HOME/bin/srvctl start database -d $SID" > /var/tmp/rac_start.log 2>&1 \
  || warn "the database did not start again, see /var/tmp/rac_start.log"

log "Cluster database state"
su - oracle -c "$ORACLE_HOME/bin/srvctl status database -d $SID" 2>&1 | sed 's/^/    /' || true
su - grid -c "$GRID_HOME/bin/crsctl stat res -t" 2>&1 | sed -n '/ora\./,/^$/p' | sed 's/^/    /' | head -20 || true

mark_done db_create
log "RAC database $SID created"
