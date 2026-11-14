#!/usr/bin/env bash
# 05-oracle-database.sh - creates the clustered database on the shared volume.
#
# The database is created on ha1 while /u02 is mounted by hand. Everything that
# has to survive a failover (datafiles, online redo logs, control files,
# archive logs, SPFILE) is kept under /u02; the Oracle home stays local.
# The instance is shut down again at the end so that Pacemaker can own it.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Vagrant copies the scripts to the guest under /home/vagrant/ha-lab, which is
# also where ./lab invokes them from; keep a fallback for ad-hoc copies.
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/ha-lab/scripts
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
# Settings that have to live in the shared SPFILE are applied further down: at
# this point the instance still runs from the local SPFILE, so "scope=spfile"
# would update the file that gets retired a few lines later.
cat > /var/tmp/spfile_move.sql <<SQL
startup force
create pfile='/var/tmp/init_${SID}.ora' from spfile;
create spfile='$ADMIN_DIR/pfile/spfile${SID}.ora' from pfile='/var/tmp/init_${SID}.ora';
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

log "Configuring the shared SPFILE and enabling archivelog mode"
cat > /var/tmp/spfile_tune.sql <<SQL
startup mount
alter system set db_recovery_file_dest='$SHARED_ROOT/fast_recovery_area' scope=both;
alter system set db_recovery_file_dest_size=2G scope=both;
alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=$LAB_SERVICE_IP)(PORT=1521))' scope=both;
alter database archivelog;
alter database open;
shutdown immediate
exit
SQL
su - oracle -c "sqlplus -s -L / as sysdba @/var/tmp/spfile_tune.sql" > /var/tmp/sqlplus_tune.log 2>&1 \
  || { tail -n 30 /var/tmp/sqlplus_tune.log >&2; die "could not configure the shared SPFILE"; }

# Remote SYSDBA ("sqlplus sys/... @//<service ip> as sysdba") reads
# $ORACLE_HOME/dbs/orapw$SID, and dbca only writes that on the node it ran on.
# The file is node-local, so every node needs an identical copy of it.
log "Copying the password file to $LAB_PEER"
PEER="root@$LAB_PEER_CLIENT_IP"
if [ -f "$ORACLE_HOME/dbs/orapw${SID}" ]; then
  if scp -q "$ORACLE_HOME/dbs/orapw${SID}" "$PEER:/var/tmp/orapw${SID}" 2>/dev/null; then
    ssh "$PEER" "install -m 0640 -o oracle -g oinstall /var/tmp/orapw${SID} '$ORACLE_HOME/dbs/orapw${SID}' && rm -f /var/tmp/orapw${SID}" \
      || warn "could not install the password file on $LAB_PEER"
  else
    warn "could not copy the password file to $LAB_PEER, remote SYSDBA will only work on $LAB_NODE"
  fi
fi

mark_done oracle_database
log "Database $SID created on shared storage and shut down"
