#!/usr/bin/env bash
# 05-oracle-database.sh - creates the clustered database on the shared volume.
#
# The database is created on vcs1 while /u02 is mounted by hand. Everything that
# has to survive a failover (datafiles, online redo logs, control files,
# archive logs, SPFILE) is kept under /u02; the Oracle home stays local.
# The instance is shut down again at the end so that VCS can own it.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Vagrant copies the scripts to the guest under /home/vagrant/vcs-lab, which is
# also where ./lab invokes them from; keep a fallback for ad-hoc copies.
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/vcs-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_ORACLE_SID:?LAB_ORACLE_SID is not set}"
: "${LAB_SERVICE_IP:?LAB_SERVICE_IP is not set}"

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID}
PASSWORD=${LAB_ORACLE_PASSWORD:-Oracle123}
SHARED_ROOT=/u02/app/oracle
ADMIN_DIR="$SHARED_ROOT/admin/$SID"

if [ "$LAB_ROLE" != "primary" ]; then
  info "the database is created on the primary node only, nothing to do on $LAB_NODE"
  mark_done oracle_database
  exit 0
fi

if step_done oracle_database; then
  info "database creation already completed"
  exit 0
fi

if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
  warn "Oracle software is not installed yet; re-run this step after 04-oracle-install.sh"
  exit 0
fi

log "Making sure the shared filesystem is available"
if ! mountpoint -q /u02; then
  vgchange --activate y vg_ora >/dev/null
  mount /dev/vg_ora/lv_u02 /u02
fi

install -d -m 0775 -o oracle -g oinstall \
  "$SHARED_ROOT/oradata" "$ADMIN_DIR" "$ADMIN_DIR/adump" \
  "$ADMIN_DIR/pfile" "$SHARED_ROOT/fast_recovery_area"
chown -R oracle:oinstall "$SHARED_ROOT"

if [ -f "$SHARED_ROOT/oradata/system01.dbf" ]; then
  info "datafiles already exist, skipping database creation"
else
  log "Creating database $SID (this takes a while)"
  cat > /var/tmp/create_db.sh <<EOF
#!/bin/bash
set -e
dbca -silent -createDatabase \\
  -templateName General_Purpose.dbc \\
  -gdbName $SID -sid $SID \\
  -createAsContainerDatabase false \\
  -sysPassword $PASSWORD -systemPassword $PASSWORD \\
  -datafileDestination $SHARED_ROOT/oradata \\
  -recoveryAreaDestination $SHARED_ROOT/fast_recovery_area \\
  -recoveryAreaSize 2048 \\
  -storageType FS \\
  -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \\
  -initParams "audit_file_dest=$ADMIN_DIR/adump,diagnostic_dest=$SHARED_ROOT" \\
  -emConfiguration NONE \\
  -redoLogFileSize 50 \\
  -totalMemory 1200 \\
  -sampleSchema false
EOF
  chmod 0755 /var/tmp/create_db.sh
  if ! su - oracle -c /var/tmp/create_db.sh > /var/tmp/dbca.log 2>&1; then
    tail -n 40 /var/tmp/dbca.log >&2
    die "dbca failed, see /var/tmp/dbca.log"
  fi
fi

log "Moving the SPFILE to shared storage"
cat > /var/tmp/spfile_move.sql <<SQL
startup force
create pfile='/var/tmp/init_${SID}.ora' from spfile;
create spfile='$ADMIN_DIR/pfile/spfile${SID}.ora' from pfile='/var/tmp/init_${SID}.ora';
alter system set db_recovery_file_dest='$SHARED_ROOT/fast_recovery_area' scope=spfile;
alter system set db_recovery_file_dest_size=2G scope=spfile;
alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=$LAB_SERVICE_IP)(PORT=1521))' scope=spfile;
shutdown immediate
exit
SQL
su - oracle -c "sqlplus -s -L / as sysdba @/var/tmp/spfile_move.sql" > /var/tmp/sqlplus_spfile.log 2>&1 \
  || { tail -n 30 /var/tmp/sqlplus_spfile.log >&2; die "could not create the shared SPFILE"; }

# A local spfile would take precedence over the init file, so retire it and
# leave only the one-line pointer to the shared SPFILE behind.
if [ -f "$ORACLE_HOME/dbs/spfile${SID}.ora" ]; then
  mv -f "$ORACLE_HOME/dbs/spfile${SID}.ora" "$ORACLE_HOME/dbs/spfile${SID}.ora.local-backup"
fi
echo "SPFILE=$ADMIN_DIR/pfile/spfile${SID}.ora" > "$ORACLE_HOME/dbs/init${SID}.ora"
chown oracle:oinstall "$ORACLE_HOME/dbs/init${SID}.ora"

log "Enabling archivelog mode"
cat > /var/tmp/archivelog.sql <<'SQL'
startup mount
alter database archivelog;
alter database open;
shutdown immediate
exit
SQL
su - oracle -c "sqlplus -s -L / as sysdba @/var/tmp/archivelog.sql" > /var/tmp/sqlplus_arch.log 2>&1 \
  || { tail -n 30 /var/tmp/sqlplus_arch.log >&2; die "could not enable archivelog mode"; }

mark_done oracle_database
log "Database $SID created on shared storage and shut down"
