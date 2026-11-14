#!/usr/bin/env bash
# 08-oracle-database.sh - creates the database on site A's replicated LUN.
#
# Everything that has to survive a site loss lives on the two replicated LUNs:
# datafiles, online redo and control files on /u02, archive logs and the FRA on
# /u03, and the SPFILE on /u02. The Oracle home stays local to each site, which
# is how array-based DR is normally deployed.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/dr-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_SITE_ROLE:?LAB_SITE_ROLE is not set}"
: "${LAB_ORACLE_SID:?LAB_ORACLE_SID is not set}"
: "${LAB_SERVICE_IP:?LAB_SERVICE_IP is not set}"

if [ "$LAB_SITE_ROLE" != "primary" ]; then
  info "the database is created at site A only, nothing to do on $LAB_NODE"
  mark_done oracle_database
  exit 0
fi

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID}
PASSWORD=${LAB_ORACLE_PASSWORD:-Oracle123}
DATA_ROOT=/u02/app/oracle
FRA_ROOT=/u03/app/oracle/fast_recovery_area
ADMIN_DIR="$DATA_ROOT/admin/$SID"

if step_done oracle_database; then
  info "database creation already completed"
  exit 0
fi
if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
  warn "the Oracle software is not installed on $LAB_NODE"
  info "put the 19c media in dr-oracle/software/ and re-run the oracle_install step,"
  info "then run ./lab database again"
  exit 0
fi

mountpoint -q /u02 || die "/u02 is not mounted - run the db_storage step first"
mountpoint -q /u03 || die "/u03 is not mounted - run the db_storage step first"

install -d -m 0775 -o oracle -g oinstall \
  "$DATA_ROOT/oradata" "$ADMIN_DIR" "$ADMIN_DIR/adump" "$ADMIN_DIR/pfile" "$FRA_ROOT"
chown -R oracle:oinstall "$DATA_ROOT" "$FRA_ROOT"

# dbca refuses to create a SID it finds in $ORACLE_HOME/dbs or in /etc/oratab, and
# the oracle_install step writes both on every node so that the DR site can open
# the replicated database. Hide them for the duration of the creation.
hide_local_config() {
  local f
  for f in "$ORACLE_HOME/dbs/init${SID}.ora" "$ORACLE_HOME/dbs/spfile${SID}.ora"; do
    if [ -f "$f" ]; then
      mv -f "$f" "$f.predbca"
    fi
  done
  if grep -q "^${SID}:" /etc/oratab; then
    cp -a /etc/oratab /etc/oratab.predbca
    sed -i "/^${SID}:/d" /etc/oratab
  fi
}

restore_local_config() {
  local f
  for f in "$ORACLE_HOME/dbs/init${SID}.ora.predbca" \
           "$ORACLE_HOME/dbs/spfile${SID}.ora.predbca"; do
    if [ -f "$f" ]; then
      mv -f "$f" "${f%.predbca}"
    fi
  done
  grep -q "^${SID}:" /etc/oratab || echo "${SID}:${ORACLE_HOME}:N" >> /etc/oratab
}

if find "$DATA_ROOT/oradata" -maxdepth 2 -name 'system01.dbf' 2>/dev/null | grep -q .; then
  info "datafiles already exist, skipping database creation"
else
  log "Creating database $SID (this takes a while)"
  hide_local_config
  cat > /var/tmp/create_db.sh <<EOF
#!/bin/bash
set -e
dbca -silent -createDatabase \\
  -templateName General_Purpose.dbc \\
  -gdbName $SID -sid $SID \\
  -createAsContainerDatabase false \\
  -sysPassword $PASSWORD -systemPassword $PASSWORD \\
  -datafileDestination $DATA_ROOT/oradata \\
  -recoveryAreaDestination $FRA_ROOT \\
  -recoveryAreaSize 4096 \\
  -storageType FS \\
  -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \\
  -initParams "audit_file_dest=$ADMIN_DIR/adump,diagnostic_dest=$DATA_ROOT" \\
  -emConfiguration NONE \\
  -redoLogFileSize 50 \\
  -totalMemory 1200 \\
  -sampleSchema false
EOF
  chmod 0755 /var/tmp/create_db.sh
  if ! su - oracle -c /var/tmp/create_db.sh > /var/tmp/dbca.log 2>&1; then
    restore_local_config
    tail -n 40 /var/tmp/dbca.log >&2
    die "dbca failed, see /var/tmp/dbca.log"
  fi
  restore_local_config
fi

log "Moving the SPFILE to the replicated LUN"
# The instance still runs from the local SPFILE here, so "scope=spfile" would
# update the file that is retired a few lines below; the settings follow once
# the instance runs from the shared SPFILE.
cat > /var/tmp/spfile_move.sql <<SQL
startup force
create pfile='/var/tmp/init_${SID}.ora' from spfile;
create spfile='$ADMIN_DIR/pfile/spfile${SID}.ora' from pfile='/var/tmp/init_${SID}.ora';
shutdown immediate
exit
SQL
su - oracle -c "sqlplus -s -L / as sysdba @/var/tmp/spfile_move.sql" > /var/tmp/sqlplus_spfile.log 2>&1 \
  || { tail -n 30 /var/tmp/sqlplus_spfile.log >&2; die "could not create the shared SPFILE"; }

if [ -f "$ORACLE_HOME/dbs/spfile${SID}.ora" ]; then
  mv -f "$ORACLE_HOME/dbs/spfile${SID}.ora" "$ORACLE_HOME/dbs/spfile${SID}.ora.local-backup"
fi
echo "SPFILE=$ADMIN_DIR/pfile/spfile${SID}.ora" > "$ORACLE_HOME/dbs/init${SID}.ora"
chown oracle:oinstall "$ORACLE_HOME/dbs/init${SID}.ora"
chmod 0640 "$ORACLE_HOME/dbs/init${SID}.ora"

log "Configuring the replicated SPFILE and enabling archivelog mode"
cat > /var/tmp/spfile_tune.sql <<SQL
startup mount
alter system set db_recovery_file_dest='$FRA_ROOT' scope=both;
alter system set db_recovery_file_dest_size=4G scope=both;
alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=$LAB_SERVICE_IP)(PORT=1521))' scope=both;
alter database archivelog;
alter database open;
exit
SQL
su - oracle -c "sqlplus -s -L / as sysdba @/var/tmp/spfile_tune.sql" > /var/tmp/sqlplus_tune.log 2>&1 \
  || { tail -n 30 /var/tmp/sqlplus_tune.log >&2; die "could not configure the shared SPFILE"; }

# The demo table belongs to SYSTEM, which is the account ./lab sql uses; a table
# created from the SYSDBA connection would live in SYS and stay invisible to it.
log "Creating the DR demo table in the SYSTEM schema"
cat > /var/tmp/demo_table.sql <<SQL
whenever sqlerror exit failure
declare
  n number;
begin
  select count(*) into n from user_tables where table_name = 'DR_TEST';
  if n = 0 then
    -- both statements are dynamic: a static INSERT would be resolved at compile
    -- time, when the table created a line earlier does not exist yet.
    execute immediate 'create table dr_test ('
      || 'id number generated always as identity, '
      || 'ts timestamp default systimestamp, '
      || 'site varchar2(10), note varchar2(60))';
    execute immediate q'[insert into dr_test (site, note) values ('A', 'base row created with the database')]';
    commit;
  end if;
end;
/
select 'dr_test rows: ' || count(*) as rows_in_dr_test from dr_test;
exit
SQL
su - oracle -c "sqlplus -s -L system/$PASSWORD @/var/tmp/demo_table.sql" > /var/tmp/sqlplus_table.log 2>&1 \
  || { tail -n 30 /var/tmp/sqlplus_table.log >&2; die "could not create the demo table"; }
sed 's/^/    /' /var/tmp/sqlplus_table.log | grep -v '^\s*$' | tail -3

su - oracle -c "sqlplus -s -L / as sysdba" >/dev/null 2>&1 <<'SQL'
shutdown immediate
exit
SQL

mark_done oracle_database
log "Database $SID created on the replicated LUN; bringing site $LAB_NODE online"

# Start the instance, the listener and the service address through the same
# code path that a DR promotion uses, so both directions are exercised.
bash "$SCRIPT_DIR/dr-action.sh" start-db
