#!/usr/bin/env bash
# 09-dr-prepare.sh - validates the DR site and leaves it ready but idle.
#
# Nothing is mounted and no instance runs at site B. The proof that the blocks
# really arrived is taken on the array (dr-action.sh verify-replica reads the
# replicated filesystem from the DRBD device); here we only check that the local
# Oracle home, the init file and the service address configuration are in place,
# so that a promotion needs nothing but the promotion itself.
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

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID}

if [ "$LAB_SITE_ROLE" = "primary" ]; then
  info "site $LAB_NODE is the primary site, nothing to prepare for DR"
  mark_done dr_prepare
  exit 0
fi

log "Validating the DR site $LAB_NODE"

if [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
  info "Oracle home present in $ORACLE_HOME"
else
  warn "the Oracle software is not installed here yet"
fi

if [ -f "$ORACLE_HOME/dbs/init${SID}.ora" ]; then
  info "init${SID}.ora: $(tr -d '\n' < "$ORACLE_HOME/dbs/init${SID}.ora")"
else
  warn "init${SID}.ora is missing, run the oracle_install step"
fi

if [ -f "$ORACLE_HOME/network/admin/listener.ora" ] &&
   grep -q "$LAB_SERVICE_IP" "$ORACLE_HOME/network/admin/listener.ora"; then
  info "listener.ora is bound to the service address $LAB_SERVICE_IP"
else
  warn "listener.ora does not reference $LAB_SERVICE_IP"
fi

for target in /u02 /u03; do
  if mountpoint -q "$target"; then
    warn "$target is mounted at the DR site, that is not expected"
  else
    info "$target is not mounted (correct: nothing may write here yet)"
  fi
done

if systemctl is-active iscsid >/dev/null 2>&1; then
  info "iscsid is running and reconnects to the array at boot"
else
  warn "iscsid is not running"
fi

if [ -e "${LAB_LUN0:-/nonexistent}" ]; then
  info "the array is presenting LUNs here already (promoted site)"
else
  info "no LUN is presented yet: the array at this site is still a replication target"
fi

info "replication proof for this site: ./lab verify compares both copies block by block"
mark_done dr_prepare
log "DR site $LAB_NODE is ready: it becomes active only after ./lab failover"
