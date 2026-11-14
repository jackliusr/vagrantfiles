#!/usr/bin/env bash
# 03-oracle-prereq.sh - creates the Oracle owner account, kernel parameters,
# shell limits and the local software directories the 19c installer expects.
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

ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
INVENTORY=/u01/app/oraInventory

log "Installing Oracle 19c preinstallation requirements on $LAB_NODE"
if dnf install -y oracle-database-preinstall-19c >/dev/null 2>&1; then
  info "oracle-database-preinstall-19c installed"
else
  warn "oracle-database-preinstall-19c is not available, applying the settings manually"

  for spec in "oinstall:54321" "dba:54322" "oper:54323" "backupdba:54324" \
              "dgdba:54325" "kmdba:54326" "racdba:54327"; do
    group=${spec%%:*}
    gid=${spec##*:}
    getent group "$group" >/dev/null || groupadd -g "$gid" "$group" || die "cannot create group $group"
  done
  if ! getent passwd oracle >/dev/null; then
    useradd -u 54321 -g oinstall \
      -G dba,oper,backupdba,dgdba,kmdba,racdba \
      -c "Oracle software owner" -m -s /bin/bash oracle \
      || die "cannot create the oracle user"
  fi

  cat > /etc/sysctl.d/98-oracle-19c.conf <<'EOF'
fs.aio-max-nr = 1048576
fs.file-max = 6815744
kernel.shmall = 1073741824
kernel.shmmax = 4398046511104
kernel.shmmni = 4096
kernel.sem = 250 32000 100 128
net.ipv4.ip_local_port_range = 9000 65500
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
EOF
  sysctl --system >/dev/null

  cat > /etc/security/limits.d/98-oracle-19c.conf <<'EOF'
oracle   soft   nofile    1024
oracle   hard   nofile    65536
oracle   soft   nproc     16384
oracle   hard   nproc     16384
oracle   soft   stack     10240
oracle   hard   stack     10240
oracle   soft   memlock   134217728
oracle   hard   memlock   134217728
EOF
fi

log "Disabling transparent huge pages"
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable transparent huge pages for Oracle
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service >/dev/null 2>&1 || warn "could not disable THP"

log "Creating the Oracle directory layout"
install -d -m 0775 -o oracle -g oinstall "$ORACLE_BASE"
install -d -m 0775 -o oracle -g oinstall "$(dirname "$ORACLE_HOME")"
install -d -m 0775 -o oracle -g oinstall "$ORACLE_HOME"
install -d -m 0775 -o oracle -g oinstall "$INVENTORY"
install -d -m 0775 -o oracle -g oinstall /u01/app/oracle/product/19.0.0/dbhome_1/cfgtoollogs

cat > /etc/oraInst.loc <<EOF
inventory_loc=$INVENTORY
inst_group=oinstall
EOF
chmod 0644 /etc/oraInst.loc

if [ ! -f /etc/oratab ]; then
  cat > /etc/oratab <<'EOF'
# This file is used by ORACLE utilities. It is created by root.sh and updated
# by the Database Configuration Assistant when creating a database.
# Format: $ORACLE_SID:$ORACLE_HOME:<N|Y>
EOF
fi

log "Configuring the oracle user environment"
cat > /home/oracle/.bash_profile <<EOF
# Oracle 19c environment for the HA lab
export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$ORACLE_HOME
export ORACLE_SID=$LAB_ORACLE_SID
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
umask 022
EOF
chown oracle:oinstall /home/oracle/.bash_profile
chmod 0644 /home/oracle/.bash_profile

# Sourced by the Pacemaker oracle and oralsnr resource agents.
cat > /home/oracle/.oraenv_ha <<EOF
ORACLE_BASE=$ORACLE_BASE; export ORACLE_BASE
ORACLE_HOME=$ORACLE_HOME; export ORACLE_HOME
ORACLE_SID=$LAB_ORACLE_SID; export ORACLE_SID
PATH=\$ORACLE_HOME/bin:\$PATH; export PATH
LD_LIBRARY_PATH=\$ORACLE_HOME/lib; export LD_LIBRARY_PATH
NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'; export NLS_DATE_FORMAT
EOF
chown oracle:oinstall /home/oracle/.oraenv_ha
chmod 0644 /home/oracle/.oraenv_ha

# The database (datafiles, archive logs, shared spfile) lives on the shared
# mount, which only exists on the node that currently owns it.
if mountpoint -q /u02; then
  install -d -m 0775 -o oracle -g oinstall \
    /u02/app/oracle/oradata \
    /u02/app/oracle/admin \
    /u02/app/oracle/fast_recovery_area
fi

mark_done oracle_prereq
log "Oracle prerequisites finished"
