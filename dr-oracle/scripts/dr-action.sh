#!/usr/bin/env bash
# dr-action.sh - the operational side of the lab: promote or demote an array,
# stop or start the database at a site, change the replication mode, shape the
# WAN link. ./lab calls this; every subcommand is also safe to run by hand.
#
#   promote-array     make this site's array writable and present its LUNs
#   demote-array      unpresent the LUNs and give the write role away
#   present-luns      export the LUNs of an array that is already Primary
#   unpresent-luns    remove the LUN exports (needed before a demotion)
#   verify-replica    read the replicated filesystem from the DRBD device
#   check-sync        verify the array's peer is fully in sync
#   rescan            re-read the LUN map of the iSCSI session (db host)
#   stop-db           stop the instance, the listener and the service address
#   start-db          mount, start the instance and the listener, publish the VIP
#   mode sync|async   switch DRBD between protocol C and protocol A
#   wan DELAY         change the netem delay on the replication link (0 = off)
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
: "${LAB_ROLE:?LAB_ROLE is not set}"

ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SID=${LAB_ORACLE_SID:-orcl}
RESOURCES=${LAB_DRBD_RESOURCES:-"ora_data ora_fra"}

requires_array() {
  [ "$LAB_ROLE" = "array" ] || die "$1 only makes sense on an array appliance, not on $LAB_NODE"
}
requires_db() {
  [ "$LAB_ROLE" = "db" ] || die "$1 only makes sense on a database host, not on $LAB_NODE"
}

ora_sql() {
  su - oracle -c "sqlplus -s -L / as sysdba" <<<"$1"
}

clean_sql() {
  grep -vE '^(ORA-|SP2-|ERROR at line|Process ID|Session ID|Enter user-name|Usage|SQL>|\s*$)' |
    awk 'NR <= 3'
}

# Output is captured first: "grep -q" would close the pipe early and sqlplus
# would die of SIGPIPE, which "set -o pipefail" then reports as a failure.
db_running() {
  local out
  out=$(ora_sql "select 1 from dual; exit" 2>/dev/null || true)
  case $out in
    *1*) return 0 ;;
    *)   return 1 ;;
  esac
}

# An instance that refuses connections can still have its background processes
# running (an interrupted shutdown looks exactly like that), and those keep the
# filesystems busy.
instance_alive() {
  pgrep -u oracle -f "ora_pmon_$SID" >/dev/null 2>&1
}

stop_instance() {
  local i pid
  if db_running; then
    ora_sql "shutdown immediate
exit" | clean_sql | sed 's/^/    /' || true
  else
    info "the instance is not accepting connections"
  fi
  instance_alive || return 0

  warn "the instance is still up, aborting it"
  ora_sql "shutdown abort
exit" >/dev/null 2>&1 || true
  for i in $(seq 1 20); do
    instance_alive || return 0
    sleep 3
  done

  warn "the instance did not stop, terminating its background processes"
  for pid in $(pgrep -u oracle -f "ora_.*_$SID"); do
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 3
  instance_alive && warn "Oracle processes are still present, see ./lab status"
  return 0
}

vip_present() {
  local out
  out=$(ip -4 -o addr show dev "$LAB_APP_NIC" 2>/dev/null || true)
  case $out in
    *" ${LAB_SERVICE_IP}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- array side

role_of() { drbdadm role "$1" 2>/dev/null || echo Unknown; }

# Backstore name -> DRBD device. Both arrays use the same names, so the site
# that gets promoted presents the LUNs with the same LUN numbers as before.
# "backstore:drbd resource:device" - the backstore name and the DRBD resource
# name differ, and both are used below.
BACKSTORES="oradata:ora_data:/dev/drbd0 orafra:ora_fra:/dev/drbd1"

lun_line() {
  targetcli ls "/iscsi/$LAB_ISCSI_IQN/tpg1/luns" 2>/dev/null |
    grep -E "block/$1 " | head -n 1
}

# A real array presents a LUN to a host only from the controller that owns it.
# DRBD is the same: a Secondary cannot be opened for writing, so the LUNs are
# added on promotion and removed before a demotion.
present_luns() {
  requires_array present-luns
  local pair name res dev role
  role=$(role_of ora_data)
  [ "$role" = "Primary" ] || die "the array is $role; only a Primary can present writable LUNs"

  for pair in $BACKSTORES; do
    name=$(cut -d: -f1 <<<"$pair")
    dev=$(cut -d: -f3 <<<"$pair")
    if targetcli ls /backstores/block 2>/dev/null | grep -qw "$name"; then
      info "backstore $name already present"
    else
      targetcli /backstores/block create name="$name" dev="$dev" >/dev/null \
        || die "could not create the $name backstore on $dev"
      info "backstore $name -> $dev"
    fi
    if [ -n "$(lun_line "$name")" ]; then
      info "LUN for $name already exported"
    else
      targetcli "/iscsi/$LAB_ISCSI_IQN/tpg1/luns" create "/backstores/block/$name" >/dev/null \
        || die "could not export $name"
      info "LUN for $name exported"
    fi
  done
  targetcli saveconfig >/dev/null 2>&1 || warn "could not save the target configuration"
}

unpresent_luns() {
  requires_array unpresent-luns
  local pair name dev lun_id
  for pair in $BACKSTORES; do
    name=$(cut -d: -f1 <<<"$pair")
    lun_id=$(lun_line "$name" | grep -oE 'lun[0-9]+' | sed -n '1p' | tr -dc '0-9')
    if [ -n "$lun_id" ]; then
      targetcli "/iscsi/$LAB_ISCSI_IQN/tpg1/luns" delete "$lun_id" >/dev/null 2>&1 \
        || warn "could not delete LUN $lun_id ($name)"
      info "LUN $lun_id ($name) removed"
    fi
    if targetcli ls /backstores/block 2>/dev/null | grep -qw "$name"; then
      targetcli /backstores/block delete "$name" >/dev/null 2>&1 \
        || warn "could not delete the $name backstore"
      info "backstore $name removed"
    fi
  done
  targetcli saveconfig >/dev/null 2>&1 || true
}

# Reports whether the two copies of each LUN are still block-identical. DRBD
# refuses every open of a Secondary device, so the replica cannot be read
# directly; the supported check is the online verification, which compares
# checksums with the other site over the replication link.
verify_replica() {
  requires_array verify-replica
  local run=false pair name res dev role state
  [ "${1:-}" = "--run" ] && run=true

  for pair in $BACKSTORES; do
    name=$(cut -d: -f1 <<<"$pair")
    res=$(cut -d: -f2 <<<"$pair")
    dev=$(cut -d: -f3 <<<"$pair")
    role=$(role_of "$res")
    state=$(drbdadm status "$res" 2>/dev/null | tr '\n' ' ' | tr -s ' ' || true)
    case $state in
      *"disk:UpToDate"*"peer-disk:UpToDate"*) info "$name ($res, /dev/drbd$([ "$res" = ora_data ] && echo 0 || echo 1)): local $role, both copies UpToDate" ;;
      *) warn "$name ($res): local $role, copies are NOT in sync" ;;
    esac
    printf '      %s\n' "$state"

    if [ "$run" = true ]; then
      drbdadm verify "$res" || { warn "could not start the verification of $res"; continue; }
      info "$res: online verification started (checksums of both copies)"
      local deadline=$((SECONDS + 600)) progress
      while [ "$SECONDS" -lt "$deadline" ]; do
        progress=$(drbdsetup status "$res" --statistics 2>/dev/null |
          grep -oE 'replication:[A-Za-z]+|done:[0-9.]+|out-of-sync:[0-9]+' | tr '\n' ' ')
        case $progress in
          *Verify*)
            info "  $res: $progress"
            sleep 20
            ;;
          *)
            info "  $res: verification finished ($progress)"
            break
            ;;
        esac
      done
    fi
  done
}

promote_array() {
  requires_array promote-array
  log "Promoting the array at site $LAB_SITE (breaking replication if needed)"
  local res role
  for res in $RESOURCES; do
    role=$(role_of "$res")
    if [ "$role" = "Primary" ]; then
      info "$res is already Primary"
      continue
    fi
    if [ "$role" = "Unknown" ]; then
      drbdadm up "$res" || die "$res is not up locally, is the disk attached?"
      role=$(role_of "$res")
    fi
    # --force is what a DR runbook calls "break the mirror": the promotion must
    # work even though the other site is gone and can no longer acknowledge.
    drbdadm primary --force "$res" || die "could not promote $res"
    info "$res promoted to Primary"
  done

  for res in $RESOURCES; do
    wait_until 30 "$res to report Primary" \
      bash -c "[ \"\$(drbdadm role $res)\" = Primary ]" || true
  done
  drbdadm status | sed 's/^/    /'
  log "Presenting the LUNs to the database host"
  present_luns
  info "the LUNs are writable now; the database host may mount them"
}

demote_array() {
  requires_array demote-array
  local res role
  log "Giving up the write role at site $LAB_SITE"
  # The target holds the device open, and DRBD refuses to go Secondary while
  # somebody else has the device open, so the LUNs go away first.
  unpresent_luns
  for res in $RESOURCES; do
    role=$(role_of "$res")
    [ "$role" = "Primary" ] || { info "$res is $role"; continue; }
    drbdadm secondary "$res" || die "could not demote $res (is a filesystem still mounted at the DB host?)"
    info "$res demoted to Secondary"
  done
  drbdadm status | sed 's/^/    /'
}

# Returns non-zero unless every resource reports an up-to-date peer, which is
# the precondition for a switchover without data loss.
check_sync() {
  requires_array check-sync
  local res out ok=0
  for res in $RESOURCES; do
    out=$(drbdadm status "$res" 2>/dev/null)
    if printf '%s\n' "$out" | grep -q 'peer-disk:UpToDate'; then
      info "$res: peer is UpToDate ($(printf '%s\n' "$out" | awk '/replication:/ {print $2}' | head -n 1))"
    else
      warn "$res: the peer is not up to date"
      printf '%s\n' "$out" | sed 's/^/      /'
      ok=1
    fi
  done
  return $ok
}

set_mode() {
  requires_array mode
  local wanted=${1:-sync} proto file
  case $wanted in
    sync)  proto="C" ;;
    async) proto="A" ;;
    *) die "usage: dr-action.sh mode sync|async" ;;
  esac
  log "Setting replication to protocol $proto ($wanted) on $LAB_NODE"
  for file in /etc/drbd.d/*.res; do
    [ -f "$file" ] || continue
    sed -i "s/^  protocol [ABC];/  protocol $proto;/" "$file"
  done
  for res in $RESOURCES; do
    drbdadm adjust "$res" || warn "could not adjust $res"
  done
  drbdadm status | sed 's/^/    /'
  if [ "$proto" = "A" ]; then
    info "asynchronous: the primary no longer waits for the DR site (loss window > 0)"
  else
    info "synchronous: a commit is only acknowledged once the DR site has the block"
  fi
}

set_wan() {
  requires_array wan
  local delay=${1:?usage: dr-action.sh wan DELAY (e.g. 5ms, 0)}
  [ -n "${LAB_REPL_NIC:-}" ] || die "LAB_REPL_NIC is unknown, run the array step first"
  if [ "$delay" = "0" ] || [ "$delay" = "0ms" ]; then
    tc qdisc del dev "$LAB_REPL_NIC" root 2>/dev/null || true
    info "netem removed from $LAB_REPL_NIC"
  else
    tc qdisc replace dev "$LAB_REPL_NIC" root netem delay "$delay" 1ms \
      || die "could not set the netem delay"
    info "$LAB_REPL_NIC: one-way delay $delay +-1ms (round trip ~2x)"
  fi
}

# ------------------------------------------------------------------- db side

# After the array at this site has been demoted it presents no LUNs; a rescan
# drops the stale devices so that nothing can write to a replica by accident.
rescan_luns() {
  requires_db rescan
  local lun real
  for lun in /u02 /u03; do
    if mountpoint -q "$lun"; then
      warn "$lun is still mounted here, not touching the iSCSI devices"
      return 0
    fi
  done

  # Removing a LUN from the target does not remove the device from the host, and
  # leaving it around invites somebody to write to a replica. Deleting the SCSI
  # device and letting the rescan re-add whatever is really presented keeps the
  # two views identical.
  for lun in "${LAB_LUN0:-}" "${LAB_LUN1:-}"; do
    [ -n "$lun" ] || continue
    real=$(readlink -f "$lun" 2>/dev/null || true)
    if [ -n "$real" ] && [ -e "/sys/block/$(basename "$real")/device/delete" ]; then
      echo 1 > "/sys/block/$(basename "$real")/device/delete"
      info "dropped the stale device $real"
    fi
  done

  iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" --logout >/dev/null 2>&1 || true
  iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" --login >/dev/null 2>&1 || true
  iscsiadm -m session --rescan >/dev/null 2>&1 || true

  for lun in "${LAB_LUN0:-}" "${LAB_LUN1:-}"; do
    [ -n "$lun" ] || continue
    if [ -e "$lun" ]; then
      info "$lun is presented by the array"
    else
      info "$lun is not presented at this site"
    fi
  done
}

stop_db() {
  requires_db stop-db
  log "Stopping the database at site $LAB_SITE"
  stop_instance
  su - oracle -c "lsnrctl stop" >/dev/null 2>&1 || true
  info "listener stopped"

  for target in /u03 /u02; do
    if mountpoint -q "$target"; then
      sync
      umount "$target" || die "could not unmount $target"
      info "$target unmounted"
    fi
  done

  if vip_present; then
    ip addr del "$LAB_SERVICE_IP/24" dev "$LAB_APP_NIC"
    info "service address $LAB_SERVICE_IP released"
  fi
}

start_db() {
  requires_db start-db
  log "Starting the database at site $LAB_SITE"

  # A session that was established while the array presented no LUNs keeps its
  # empty LUN map, so log in again if a plain rescan does not reveal the device.
  iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" --login >/dev/null 2>&1 || true
  iscsiadm -m session --rescan >/dev/null 2>&1 || true
  if [ ! -e "${LAB_LUN0:?LAB_LUN0 is not set}" ]; then
    info "the array has just started presenting LUNs, refreshing the iSCSI session"
    iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" --logout >/dev/null 2>&1 || true
    iscsiadm -m node -T "$LAB_ISCSI_IQN" -p "$LAB_SAN_IP" --login >/dev/null 2>&1 || true
    iscsiadm -m session --rescan >/dev/null 2>&1 || true
  fi
  wait_until 60 "the data LUN ($LAB_LUN0)" test -e "$LAB_LUN0"

  # The service address has to exist before the listener starts: listener.ora
  # binds to it and the database registers itself through it.
  if ! vip_present; then
    ip addr add "$LAB_SERVICE_IP/24" dev "$LAB_APP_NIC" || die "could not add $LAB_SERVICE_IP"
    info "service address $LAB_SERVICE_IP added to $LAB_APP_NIC"
  fi
  # The client network is a single layer-2 segment, so a gratuitous ARP is
  # enough to move the address between the sites.
  arping -U -c 3 -I "$LAB_APP_NIC" "$LAB_SERVICE_IP" >/dev/null 2>&1 \
    || warn "could not send a gratuitous ARP"

  for pair in "oradata:/u02" "orafra:/u03"; do
    label=${pair%%:*}
    target=${pair##*:}
    if mountpoint -q "$target"; then
      info "$target is already mounted"
    else
      mount -L "$label" "$target" || die "could not mount LABEL=$label on $target"
      info "LABEL=$label mounted on $target"
    fi
  done

  if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
    warn "the Oracle software is not installed on $LAB_NODE"
    warn "the replicated filesystems and the service address are online, but no instance can run"
    info "add the media to dr-oracle/software/ and re-run the oracle_install step to finish the lab"
    return 0
  fi

  log "Opening the instance (crash recovery happens here after a hard failover)"
  ora_sql "startup
select 'inst=' || i.instance_name || ' host=' || i.host_name ||
       ' status=' || i.status || ' db=' || d.open_mode || ' log=' || d.log_mode
  from v\$instance i, v\$database d;
exit" | clean_sql | sed 's/^/    /'

  if pgrep -u oracle -f tnslsnr >/dev/null 2>&1; then
    info "the listener was already running"
  elif su - oracle -c "lsnrctl start" >/dev/null 2>&1; then
    info "listener started"
  else
    warn "the listener did not start"
  fi
  ora_sql "alter system register;
exit" >/dev/null 2>&1 || true
  info "the service re-registered with the listener"

  log "Data visible at site $LAB_SITE"
  ora_sql "select 'rows in system.dr_test=' || count(*) from system.dr_test;
select 'last row: id=' || id || ' site=' || site || ' note=' || note
  from (select id, site, note from system.dr_test order by id desc) where rownum = 1;
exit" | clean_sql | sed 's/^/    /'
}

case "${1:-}" in
  present-luns)   present_luns ;;
  unpresent-luns) unpresent_luns ;;
  verify-replica) shift; verify_replica "${1:-}" ;;
  promote-array) promote_array ;;
  demote-array)  demote_array ;;
  check-sync)    check_sync ;;
  rescan)        rescan_luns ;;
  stop-db)       stop_db ;;
  start-db)      start_db ;;
  mode)          shift; set_mode "${1:-sync}" ;;
  wan)           shift; set_wan "${1:-}" ;;
  *)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
