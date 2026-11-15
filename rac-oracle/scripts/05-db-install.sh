#!/usr/bin/env bash
# 05-db-install.sh - Oracle Database 19c software with the RAC option, installed
# on both nodes from the first one.
#
# This is software only: the instance is created by 06-db-create.sh with dbca.
# The RAC option is what puts the Clusterware-aware binaries (and the cssd
# client) into the home, so the same home can be opened on both nodes.
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
: "${LAB_PEER_PUB_IP:?LAB_PEER_PUB_IP is not set}"
: "${LAB_DB_NAME:?LAB_DB_NAME is not set}"

SOFTWARE_DIR=${LAB_SOFTWARE_DIR:-/home/vagrant/rac-lab/software}
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
INVENTORY=/u01/app/oraInventory
STAGING=/var/tmp/db-media
LOG=/var/tmp/db-install.log
SID=${LAB_DB_NAME}

if [ "$LAB_NODE_NUMBER" != "1" ]; then
  info "the database home is installed from node 1 only (it pushes the software to $LAB_PEER)"
  exit 0
fi

# runInstaller verifies that the Oracle base and home directories are writable
# by the oracle user on every cluster node (INS-32060), so the tree must exist
# on both nodes before the installer starts - it is not created by the installer.
log "Preparing the Oracle base directories on both nodes"
for node in "$LAB_NODE" "$LAB_PEER"; do
  if [ "$node" = "$LAB_NODE" ]; then
    run=""
  else
    run="ssh -o BatchMode=yes root@$LAB_PEER_PUB_IP"
  fi
  $run bash -s <<'MKDIRS'
set -e
install -d -m 0775 -o oracle -g oinstall /u01/app/oracle
install -d -m 0775 -o oracle -g oinstall /u01/app/oracle/product
install -d -m 0775 -o oracle -g oinstall /u01/app/oracle/product/19.0.0
install -d -m 0775 -o oracle -g oinstall /u01/app/oracle/product/19.0.0/dbhome_1
MKDIRS
  info "$node: Oracle base and home directories ready"
done

if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
  media=$(find "$SOFTWARE_DIR" -maxdepth 1 -type f \
          \( -name 'LINUX.X64_*_db_home.zip' -o -name '*db_home*.zip' \) \
          2>/dev/null | sort | head -n 1)
  if [ -z "$media" ]; then
    warn "no Oracle database home zip found in $SOFTWARE_DIR"
    info "put LINUX.X64_193000_db_home.zip there and run ./lab db-software"
    exit 0
  fi
  [ -x /u01/app/19.0.0/grid/bin/crsctl ] \
    || die "Grid Infrastructure must be installed first (./lab grid)"

  info "using media: $media"
  available_mb=$(df --output=avail -m /u01 | tail -n 1)
  if [ "$available_mb" -lt 16000 ]; then
    die "/u01 has only ${available_mb} MB free, the database home needs about 16 GB"
  fi

  log "Staging and unpacking the database home"
  install -d -m 0755 "$STAGING"
  staged="$STAGING/$(basename "$media")"
  if [ ! -f "$staged" ] || [ "$(stat -c %s "$media")" -ne "$(stat -c %s "$staged")" ]; then
    cp -f "$media" "$staged"
  fi
  chown oracle:oinstall "$staged"

  install -d -m 0775 -o oracle -g oinstall "$ORACLE_BASE"
  install -d -m 0775 -o oracle -g oinstall "$(dirname "$ORACLE_HOME")"
  install -d -m 0775 -o oracle -g oinstall "$ORACLE_HOME"
  su - oracle -c "unzip -q -o '$staged' -d '$ORACLE_HOME'" || die "unzip failed"

  log "Writing the database response file"
  # CLUSTER_NODES plus isRACOneInstall=false is what makes this a RAC software
  # installation: it installs the Clusterware-aware binaries on both nodes.
  cat > /var/tmp/db_install.rsp <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=$INVENTORY
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
oracle.install.db.isRACOneInstall=false
oracle.install.db.rac.configurationType=
oracle.install.db.CLUSTER_NODES=$LAB_NODE,$LAB_PEER
EOF
  chown oracle:oinstall /var/tmp/db_install.rsp

  # glibc 2.34 dropped libpthread_nonshared.a, which 19c's genclntsh still
  # lists; an empty archive satisfies the linker.
  if [ ! -e /usr/lib64/libpthread_nonshared.a ]; then
    ar rcs /usr/lib64/libpthread_nonshared.a
    info "created the empty /usr/lib64/libpthread_nonshared.a placeholder"
  fi

  log "Running the installer on both nodes (this takes 20-30 minutes)"
  if ! su - oracle -c "cd '$ORACLE_HOME' && CV_ASSUME_DISTID=OEL8 \
        ./runInstaller -silent -waitforcompletion -ignorePrereqFailure \
        -responseFile /var/tmp/db_install.rsp" > "$LOG" 2>&1; then
    if [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
      warn "the installer reported warnings but the software is present (see $LOG)"
    else
      tail -n 50 "$LOG" >&2
      die "the database installer failed, see $LOG"
    fi
  fi

  log "Running root.sh on $LAB_NODE"
  printf '\n' | ORACLE_HOME="$ORACLE_HOME" ORACLE_OWNER=oracle \
    LOCAL_BIN=/usr/local/bin "$ORACLE_HOME/root.sh" >> "$LOG" 2>&1 \
    || warn "root.sh on $LAB_NODE reported a problem"

  log "Running root.sh on $LAB_PEER"
  ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" \
    "printf '\n' | ORACLE_HOME='$ORACLE_HOME' ORACLE_OWNER=oracle LOCAL_BIN=/usr/local/bin '$ORACLE_HOME/root.sh' >> /var/tmp/db-root-peer.log 2>&1" \
    || warn "root.sh on $LAB_PEER reported a problem"

  for node in "$LAB_NODE" "$LAB_PEER"; do
    if [ "$node" = "$LAB_NODE" ]; then
      test -x "$ORACLE_HOME/bin/sqlplus" && info "$node: $ORACLE_HOME/bin/sqlplus present"
    else
      ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" "test -x '$ORACLE_HOME/bin/sqlplus'" \
        && info "$node: $ORACLE_HOME/bin/sqlplus present" \
        || warn "$node: the database home looks incomplete"
    fi
  done
fi

# Node-local configuration that both nodes need, whether or not the software was
# installed in this run.
log "Writing the node-local configuration on both nodes"
for node in "$LAB_NODE" "$LAB_PEER"; do
  if [ "$node" = "$LAB_NODE" ]; then
    run=""
  else
    run="ssh -o BatchMode=yes root@$LAB_PEER_PUB_IP"
  fi
  $run bash -s <<SCRIPT
set -e
cat > /home/oracle/.bash_profile <<'PROFILE'
# Oracle RAC environment for the rac-lab cluster
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
umask 022
PROFILE
chown oracle:oinstall /home/oracle/.bash_profile
grep -q "^$SID:" /etc/oratab 2>/dev/null || echo "$SID:/u01/app/oracle/product/19.0.0/dbhome_1:N" >> /etc/oratab
SCRIPT
  info "$node: oracle profile and oratab written"
done

mark_done db_install
log "Database software present on both nodes"
