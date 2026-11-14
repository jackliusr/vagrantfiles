#!/usr/bin/env bash
# 04-oracle-install.sh - silent Oracle 19c software-only installation.
#
# Place the 19c database home zip in vcs-oracle/software/ before running this
# step. Without the media the script explains what is missing and exits
# successfully, so the rest of the lab can still be provisioned.
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

LAB_SOFTWARE_DIR=${LAB_SOFTWARE_DIR:-/home/vagrant/vcs-lab/software}
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
STAGING=/var/tmp/oracle-media
INSTALL_LOG=/var/tmp/oracle-install.log

if [ -x "$ORACLE_HOME/bin/sqlplus" ] && [ -x "$ORACLE_HOME/bin/oracle" ]; then
  info "Oracle software is already installed in $ORACLE_HOME"
  mark_done oracle_install
  exit 0
fi

media=""
if [ -d "$LAB_SOFTWARE_DIR" ]; then
  media=$(find "$LAB_SOFTWARE_DIR" -maxdepth 1 -type f \
          \( -name 'LINUX.X64_*_db_home.zip' -o -name '*db_home*.zip' \) \
          | sort | head -n 1)
fi
if [ -z "$media" ]; then
  warn "no Oracle 19c database home zip found in $LAB_SOFTWARE_DIR"
  info "copy LINUX.X64_193000_db_home.zip (or the zip of a later 19c release) there and re-run:"
  info "  vagrant provision $LAB_NODE --provision-with oracle_install"
  exit 0
fi
info "using media: $media"

available_mb=$(df --output=avail -m /u01 | tail -n 1)
if [ "$available_mb" -lt 16000 ]; then
  die "/u01 has only ${available_mb} MB free, Oracle 19c needs about 16 GB (see README.md for resizing the box disk)"
fi

log "Staging the media on local disk"
install -d -m 0755 "$STAGING"
staged="$STAGING/$(basename "$media")"
if [ ! -f "$staged" ] || [ "$(stat -c %s "$media")" -ne "$(stat -c %s "$staged")" ]; then
  cp -f "$media" "$staged"
fi
chown oracle:oinstall "$staged"

log "Unpacking the Oracle home"
su - oracle -c "unzip -q -o '$staged' -d '$ORACLE_HOME'" || die "unzip failed"

log "Running the Oracle 19c installer (this takes a while)"
cat > /var/tmp/db_install.rsp <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=/u01/app/oraInventory
ORACLE_HOME=$ORACLE_HOME
ORACLE_BASE=$ORACLE_BASE
oracle.install.db.InstallEdition=EE
oracle.install.db.OSDBA_GROUP=dba
oracle.install.db.OSOPER_GROUP=oper
oracle.install.db.OSBACKUPDBA_GROUP=backupdba
oracle.install.db.OSDGDBA_GROUP=dgdba
oracle.install.db.OSKMDBA_GROUP=kmdba
oracle.install.db.OSRACDBA_GROUP=racdba
oracle.install.db.rootconfig.executeRootScript=false
EOF
chown oracle:oinstall /var/tmp/db_install.rsp

if ! su - oracle -c "cd '$ORACLE_HOME' && ./runInstaller -silent -waitforcompletion -ignorePrereqFailure -responseFile /var/tmp/db_install.rsp" \
     > "$INSTALL_LOG" 2>&1; then
  tail -n 40 "$INSTALL_LOG" >&2
  die "the Oracle installer failed, see $INSTALL_LOG"
fi

log "Running the root scripts"
if [ -x /u01/app/oraInventory/orainstRoot.sh ]; then
  /u01/app/oraInventory/orainstRoot.sh >> "$INSTALL_LOG" 2>&1 || die "orainstRoot.sh failed"
fi
if [ -x "$ORACLE_HOME/root.sh" ]; then
  printf '\n' | ORACLE_HOME="$ORACLE_HOME" ORACLE_OWNER=oracle \
    LOCAL_BIN=/usr/local/bin "$ORACLE_HOME/root.sh" >> "$INSTALL_LOG" 2>&1 \
    || die "root.sh failed, see $INSTALL_LOG"
fi

[ -x "$ORACLE_HOME/bin/sqlplus" ] || die "installation finished but $ORACLE_HOME/bin/sqlplus is missing"

# Both nodes need an init file that points the instance at the shared SPFILE;
# the SPFILE itself is created on the shared volume by 05-oracle-database.sh.
SID=${LAB_ORACLE_SID}
cat > "$ORACLE_HOME/dbs/init${SID}.ora" <<EOF
SPFILE=/u02/app/oracle/admin/$SID/pfile/spfile$SID.ora
EOF
chown oracle:oinstall "$ORACLE_HOME/dbs/init${SID}.ora"
chmod 0640 "$ORACLE_HOME/dbs/init${SID}.ora"

# The Oracle home is local to each node, so everything the agents need there
# (init file, listener definitions, oratab) has to exist on both nodes. The
# listener binds to the VCS service IP and is started by the Netlsnr agent.
log "Configuring the listener definitions for the service IP $LAB_SERVICE_IP"
install -d -m 0775 -o oracle -g oinstall "$ORACLE_HOME/network/admin"
cat > "$ORACLE_HOME/network/admin/listener.ora" <<EOF
# Started by VCS on whichever node currently owns $LAB_SERVICE_IP.
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = $LAB_SERVICE_IP)(PORT = 1521))
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))
    )
  )
EOF
cat > "$ORACLE_HOME/network/admin/tnsnames.ora" <<EOF
$SID =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LAB_SERVICE_IP)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $SID)
    )
  )
EOF
chown oracle:oinstall "$ORACLE_HOME/network/admin/listener.ora" \
                      "$ORACLE_HOME/network/admin/tnsnames.ora"

# VCS owns the instance, so never let dbstart/dbshut manage it.
if grep -q "^${SID}:" /etc/oratab; then
  sed -i "s|^${SID}:.*|${SID}:${ORACLE_HOME}:N|" /etc/oratab
else
  echo "${SID}:${ORACLE_HOME}:N" >> /etc/oratab
fi

mark_done oracle_install
log "Oracle software installed in $ORACLE_HOME"
