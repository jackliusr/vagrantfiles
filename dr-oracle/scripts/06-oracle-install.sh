#!/usr/bin/env bash
# 06-oracle-install.sh - silent Oracle 19c software-only installation.
#
# The Oracle home stays on local disk at both sites; only the database files are
# on the replicated LUNs. Without the media the script explains what is missing
# and exits successfully, so the rest of the lab can still be provisioned.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/dr-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

LAB_SOFTWARE_DIR=${LAB_SOFTWARE_DIR:-/home/vagrant/dr-lab/software}
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
STAGING=/var/tmp/oracle-media
INSTALL_LOG=/var/tmp/oracle-install.log
SID=${LAB_ORACLE_SID:-orcl}

installed=false
if [ -x "$ORACLE_HOME/bin/sqlplus" ] && [ -x "$ORACLE_HOME/bin/oracle" ]; then
  info "Oracle software is already installed in $ORACLE_HOME"
  installed=true
  # A previous run may have stopped before root.sh; finish it.
  if [ ! -x /usr/local/bin/oraenv ] && [ -x "$ORACLE_HOME/root.sh" ]; then
    log "Running the root scripts left over from the previous install"
    printf '\n' | ORACLE_HOME="$ORACLE_HOME" ORACLE_OWNER=oracle \
      LOCAL_BIN=/usr/local/bin "$ORACLE_HOME/root.sh" >> "$INSTALL_LOG" 2>&1 \
      || warn "root.sh failed, see $INSTALL_LOG"
  fi
fi

if [ "$installed" = false ]; then
  media=""
  if [ -d "$LAB_SOFTWARE_DIR" ]; then
    media=$(find "$LAB_SOFTWARE_DIR" -maxdepth 1 -type f \
            \( -name 'LINUX.X64_*_db_home.zip' -o -name '*db_home*.zip' \) \
            | sort | head -n 1)
  fi
  if [ -z "$media" ]; then
    warn "no Oracle 19c database home zip found in $LAB_SOFTWARE_DIR"
    info "put LINUX.X64_193000_db_home.zip (or the zip of a later 19c release) in"
    info "dr-oracle/software/ and re-run:"
    info "  vagrant provision $LAB_NODE --provision-with oracle_install"
    exit 0
  fi
  info "using media: $media"

  available_mb=$(df --output=avail -m /u01 | tail -n 1)
  if [ "$available_mb" -lt 16000 ]; then
    die "/u01 has only ${available_mb} MB free, Oracle 19c needs about 16 GB"
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

  # glibc 2.34 merged libpthread into libc and dropped libpthread_nonshared.a,
  # which 19c's genclntsh still lists. An empty archive satisfies the linker.
  if [ ! -e /usr/lib64/libpthread_nonshared.a ]; then
    ar rcs /usr/lib64/libpthread_nonshared.a
    info "created the empty /usr/lib64/libpthread_nonshared.a placeholder"
  fi

  # The 19c base release only knows the Oracle Linux 8 releases that existed
  # when it shipped; 'supportedOSCheck' aborts with INS-08101 otherwise.
  oui_env="CV_ASSUME_DISTID=${ORACLE_ASSUME_DISTID:-OEL8}"
  info "telling the installer to assume OL8 ($oui_env)"

  if ! su - oracle -c "cd '$ORACLE_HOME' && $oui_env ./runInstaller -silent -waitforcompletion -ignorePrereqFailure -responseFile /var/tmp/db_install.rsp" \
       > "$INSTALL_LOG" 2>&1; then
    # The installer exits non-zero when it finishes "with warning(s)".
    if [ -x "$ORACLE_HOME/bin/sqlplus" ] && [ -x "$ORACLE_HOME/bin/oracle" ]; then
      warn "the installer reported warnings but the software is present (see $INSTALL_LOG)"
    else
      tail -n 40 "$INSTALL_LOG" >&2
      die "the Oracle installer failed, see $INSTALL_LOG"
    fi
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
fi

# Node-local configuration, written on both sites: the init file points at the
# SPFILE on the replicated LUN, so the DR host can start the same instance once
# its array is promoted.
cat > "$ORACLE_HOME/dbs/init${SID}.ora" <<EOF
SPFILE=/u02/app/oracle/admin/$SID/pfile/spfile$SID.ora
EOF
chown oracle:oinstall "$ORACLE_HOME/dbs/init${SID}.ora"
chmod 0640 "$ORACLE_HOME/dbs/init${SID}.ora"

log "Configuring the listener definitions for the service IP $LAB_SERVICE_IP"
install -d -m 0775 -o oracle -g oinstall "$ORACLE_HOME/network/admin"
cat > "$ORACLE_HOME/network/admin/listener.ora" <<EOF
# Bound to the DR service address, which only exists on the active site.
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

${SID}_local =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LAB_APP_IP)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $SID)
    )
  )
EOF
chown oracle:oinstall "$ORACLE_HOME/network/admin/listener.ora" \
                      "$ORACLE_HOME/network/admin/tnsnames.ora"

# Nothing may start the instance automatically: a promoted array is a decision,
# not a boot event.
if grep -q "^${SID}:" /etc/oratab; then
  sed -i "s|^${SID}:.*|${SID}:${ORACLE_HOME}:N|" /etc/oratab
else
  echo "${SID}:${ORACLE_HOME}:N" >> /etc/oratab
fi

mark_done oracle_install
log "Oracle software installed in $ORACLE_HOME on $LAB_NODE"
