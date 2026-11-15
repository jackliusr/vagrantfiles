#!/usr/bin/env bash
# 03-grid-install.sh - Grid Infrastructure 19c (Clusterware + ASM) on both nodes.
#
# Run on the first node only: gridSetup.sh installs the software on both nodes
# over SSH and then asks for root.sh. The order matters and is enforced here:
#   orainstRoot.sh on node 1  ->  root.sh on node 1  ->  root.sh on node 2
# root.sh on node 1 establishes the cluster (and creates the OCR disk group from
# the response file), so node 2 cannot run its own root.sh before it.
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
: "${LAB_CLUSTER_NAME:?LAB_CLUSTER_NAME is not set}"
: "${LAB_SCAN_NAME:?LAB_SCAN_NAME is not set}"
: "${LAB_PRIV_IP:?LAB_PRIV_IP is not set}"
: "${LAB_PUB_IP:?LAB_PUB_IP is not set}"
: "${LAB_VIP:?LAB_VIP is not set}"
: "${LAB_PEER_PRIV_IP:?LAB_PEER_PRIV_IP is not set}"
: "${LAB_PEER_PUB_IP:?LAB_PEER_PUB_IP is not set}"
: "${LAB_PEER_VIP:?LAB_PEER_VIP is not set}"
: "${LAB_PRIV_NETWORK:?LAB_PRIV_NETWORK is not set}"
: "${LAB_PUB_NETWORK:?LAB_PUB_NETWORK is not set}"
: "${LAB_STORAGE_NETWORK:?LAB_STORAGE_NETWORK is not set}"
: "${LAB_STORAGE_NIC:?LAB_STORAGE_NIC is not set}"
: "${LAB_GRID_PASSWORD:?LAB_GRID_PASSWORD is not set}"
: "${LAB_PEER_PUB_IP:?LAB_PEER_PUB_IP is not set}"

SOFTWARE_DIR=${LAB_SOFTWARE_DIR:-/home/vagrant/rac-lab/software}
GRID_BASE=/u01/app/grid
GRID_HOME=/u01/app/19.0.0/grid
INVENTORY=/u01/app/oraInventory
STAGING=/var/tmp/grid-media
LOG=/var/tmp/grid-install.log

if [ "$LAB_NODE_NUMBER" != "1" ]; then
  info "Grid Infrastructure is installed from $LAB_NODE_NUMBER=1 only; nothing to do on $LAB_NODE"
  exit 0
fi

log "Installing Oracle Grid Infrastructure 19c on $LAB_CLUSTER_NAME"

# gridSetup.sh verifies that the grid base and home directories are writable by
# the grid user on every cluster node (INS-32063), so the tree must exist on
# both nodes before the installer starts - it is not created by the installer.
log "Preparing the Oracle base directories on both nodes"
for node in "$LAB_NODE" "$LAB_PEER"; do
  if [ "$node" = "$LAB_NODE" ]; then
    run=""
  else
    run="ssh -o BatchMode=yes root@$LAB_PEER_PUB_IP"
  fi
  $run bash -s <<'MKDIRS'
set -e
install -d -m 0775 -o grid -g oinstall /u01
install -d -m 0775 -o grid -g oinstall /u01/app
install -d -m 0775 -o grid -g oinstall /u01/app/grid
install -d -m 0775 -o grid -g oinstall /u01/app/19.0.0
install -d -m 0775 -o grid -g oinstall /u01/app/19.0.0/grid
install -d -m 0775 -o grid -g oinstall /u01/app/oraInventory
MKDIRS
  info "$node: /u01/app/grid and /u01/app/19.0.0/grid ready"
done

# The install is driven from node 1, so it needs the software visible there and
# both nodes prepared. Everything below fails loudly rather than half-installing.
# The completion marker is used rather than a file in the home: gridSetup copies
# the media there before it validates anything, so a failed run leaves the home
# looking perfectly healthy.
if step_done grid_software; then
  info "the Grid Infrastructure software is already installed"
else
  media=$(find "$SOFTWARE_DIR" -maxdepth 1 -type f \
          \( -name 'LINUX.X64_*grid_home*.zip' -o -name '*grid_home*.zip' \) \
          2>/dev/null | sort | head -n 1)
  if [ -z "$media" ]; then
    warn "no Grid Infrastructure media found in $SOFTWARE_DIR"
    info "download LINUX.X64_193000_grid_home.zip from Oracle (Grid Infrastructure"
    info "for Linux x86-64), put it in rac-oracle/software/ and run:"
    info "  ./lab grid"
    info "The cluster cannot be created without it: the database home zip does not"
    info "contain Clusterware or ASM."
    exit 0
  fi
  info "using media: $media"

  # Nothing has created /u01 yet in the RAC lab (there is no separate
  # prerequisite step), so it is created before its free space is measured.
  install -d -m 0775 -o grid -g oinstall /u01
  available_mb=$(df --output=avail -m /u01 | tail -n 1)
  if [ "$available_mb" -lt 12000 ]; then
    die "/u01 has only ${available_mb} MB free, Grid Infrastructure needs about 12 GB"
  fi

  log "Configuring the grid user environment"
  cat > /home/grid/.bash_profile <<PROFILE
# Grid Infrastructure environment for the rac-lab cluster
export ORACLE_BASE=$GRID_BASE
export ORACLE_HOME=$GRID_HOME
export ORACLE_SID=+ASM$LAB_NODE_NUMBER
export GRID_HOME=$GRID_HOME
export PATH=\$ORACLE_HOME/bin:\$ORACLE_HOME/perl/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
umask 022
PROFILE
  chown grid:oinstall /home/grid/.bash_profile
  ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" "cat > /home/grid/.bash_profile" < /home/grid/.bash_profile \
    || warn "could not write the grid profile on $LAB_PEER"

  if [ -x "$GRID_HOME/gridSetup.sh" ]; then
    info "the Grid Infrastructure home is already unpacked"
  else
    log "Staging and unpacking the Grid Infrastructure home"
    install -d -m 0755 "$STAGING"
    staged="$STAGING/$(basename "$media")"
    if [ ! -f "$staged" ] || [ "$(stat -c %s "$media")" -ne "$(stat -c %s "$staged")" ]; then
      cp -f "$media" "$staged"
    fi
    chown grid:oinstall "$staged"

    install -d -m 0775 -o grid -g oinstall "$GRID_BASE"
    install -d -m 0775 -o grid -g oinstall "$GRID_HOME"
    install -d -m 0775 -o grid -g oinstall "$INVENTORY"
    su - grid -c "unzip -q -o '$staged' -d '$GRID_HOME'" || die "unzip failed"
  fi

  log "Installing cvuqdisk on both nodes"
  # The installer runs its own cluster verification and needs this RPM on every
  # node; it only ships inside the Grid Infrastructure media.
  cvuq=$(find "$GRID_HOME" -name 'cvuqdisk*.rpm' | head -n 1)
  if [ -n "$cvuq" ]; then
    rpm -q cvuqdisk >/dev/null 2>&1 || rpm -Uvh "$cvuq" >/dev/null 2>&1 || warn "cvuqdisk install failed"
    ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" \
      "rpm -q cvuqdisk >/dev/null 2>&1 || rpm -Uvh '$cvuq' >/dev/null 2>&1 || true" \
      || warn "could not install cvuqdisk on $LAB_PEER"
    info "cvuqdisk present on both nodes"
  fi

  log "Writing the Grid Infrastructure response file"
  # The ASM disks are the udev names from 02-storage.sh. OCR uses NORMAL
  # redundancy across the three small LUNs, which is the layout a real cluster
  # uses (two failures tolerated, majority-based quorum).
  cat > /var/tmp/grid_install.rsp <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v19.0.0
oracle.install.option=CRS_CONFIG
ORACLE_BASE=$GRID_BASE
oracle.install.asm.OSDBA=asmdba
oracle.install.asm.OSOPER=asmoper
oracle.install.asm.OSASM=asmadmin
# LOCAL_SCAN: the SCAN name is resolved by each node's own resolver, which is the
# lab DNS server. SHARED_SCAN would require a SCAN client data file listing the
# addresses instead of letting DNS answer.
oracle.install.crs.config.scanType=LOCAL_SCAN
oracle.install.crs.config.gpnp.scanName=$LAB_SCAN_NAME
oracle.install.crs.config.gpnp.scanPort=1521
oracle.install.crs.config.ClusterConfiguration=STANDALONE
oracle.install.crs.config.clusterName=$LAB_CLUSTER_NAME
oracle.install.crs.config.configureAsExtendedCluster=false
oracle.install.crs.config.gpnp.configureGNS=false
oracle.install.crs.config.autoConfigureClusterNodeVIP=false
oracle.install.crs.config.clusterNodes=$LAB_NODE:$LAB_NODE-vip,$LAB_PEER:$LAB_PEER-vip
# InterfaceType: 1=PUBLIC 2=PRIVATE 3=DO NOT USE 4=ASM 5=ASM&PRIVATE.
# private interconnect = 2, public (client/VIP/SCAN) = 1, and the dedicated
# iSCSI storage network carries the ASM traffic = 4.
oracle.install.crs.config.networkInterfaceList=$LAB_PRIV_NIC:$LAB_PRIV_NETWORK:2,$LAB_PUB_NIC:$LAB_PUB_NETWORK:1,$LAB_STORAGE_NIC:$LAB_STORAGE_NETWORK:4
oracle.install.crs.config.storageOption=FLEX_ASM_STORAGE
oracle.install.crs.config.useIPMI=false
oracle.install.crs.config.ignoreDownNodes=false
oracle.install.asm.diskGroup.name=OCR
oracle.install.asm.diskGroup.redundancy=NORMAL
oracle.install.asm.diskGroup.disks=/dev/asm-disk1,/dev/asm-disk2,/dev/asm-disk3
oracle.install.asm.diskGroup.diskDiscoveryString=/dev/asm-disk*
oracle.install.asm.monitorPassword=$LAB_GRID_PASSWORD
oracle.install.asm.SYSASMPassword=$LAB_GRID_PASSWORD
oracle.install.crs.rootconfig.executeRootScript=false
EOF
  chown grid:oinstall /var/tmp/grid_install.rsp
  chmod 0644 /var/tmp/grid_install.rsp
  info "response file: /var/tmp/grid_install.rsp"

  # The installer picks the SCAN addresses up from DNS; if dnsmasq is not
  # running the cluster cannot be reached by name afterwards and gridSetup fails
  # its own check, so verify it here with a clear message.
  if ! getent hosts "$LAB_SCAN_NAME" >/dev/null 2>&1; then
    die "SCAN $LAB_SCAN_NAME does not resolve - start it on the host: sudo ./host/scan-dns.sh setup"
  fi
  info "$LAB_SCAN_NAME resolves to: $(getent hosts "$LAB_SCAN_NAME" | awk '{print $1}' | tr '\n' ' ')"

  log "Running gridSetup.sh (this takes 20-40 minutes)"
  # Earlier failed root.sh attempts can leave install/root_*.log files owned by
  # another user; gridSetup then cannot copy them to the peer (PRCF-2023).
  # The whole home is re-owned so the peer transfer never trips on permissions.
  find "$GRID_HOME/install" -maxdepth 1 -name 'root_*.log' -delete 2>/dev/null || true
  chown -R grid:oinstall "$GRID_HOME"

  # A failed previous attempt can leave a partial central inventory and a
  # non-empty Oracle base, which the installer refuses to reuse (INS-32035,
  # INS-40109). Nothing else is registered in this lab's inventory, so both are
  # reset - but only when the software itself is not installed yet: root.sh only
  # exists after gridSetup finished the software install, and wiping the
  # inventory then would destroy a good state.
  if [ ! -x "$GRID_HOME/root.sh" ]; then
    rm -rf /u01/app/oraInventory/* /u01/app/grid/* 2>/dev/null || true
    info "inventory and Oracle base reset for the retry"
  fi
  # CV_ASSUME_DISTID: the 19c base release only knows the Oracle Linux 8 releases
  # that existed when it shipped; without it OUI aborts on 8.9.
  # gridSetup only copies the media into $GRID_HOME *before* it validates the
  # response file, so the presence of files in the home says nothing about
  # whether the install succeeded. The "Successfully Setup Software" marker is
  # the trustworthy signal.
  setup_rc=0
  su - grid -c "cd '$GRID_HOME' && CV_ASSUME_DISTID=OEL8 \
        ./gridSetup.sh -silent -waitforcompletion -ignorePrereqFailure \
        -responseFile /var/tmp/grid_install.rsp" > "$LOG" 2>&1 || setup_rc=$?

  # With rootconfig.executeRootScript=false, gridSetup exits 6 after installing
  # the software and asks for the root scripts to be run by hand - which is
  # exactly what the next section does. That is success, not failure.
  if [ "$setup_rc" -eq 6 ]; then
    info "gridSetup.sh exited with 6: software installed, root scripts pending"
  elif [ "$setup_rc" -ne 0 ]; then
    warn "gridSetup.sh exited with $setup_rc (expected 6 for a successful software-only install)"
  fi
  if ! grep -q 'Successfully Setup Software' "$LOG"; then
    grep -E '^\[FATAL\]|CAUSE:|ACTION:|SUMMARY:' "$LOG" | head -20 >&2
    tail -n 15 "$LOG" >&2
    die "Grid Infrastructure software was not installed, see $LOG"
  fi
  info "software installed in $GRID_HOME"
  mark_done grid_software
fi

log "Running the root scripts in the required order"

# 1. Central inventory on every node (gridSetup reports both nodes).
for node in "$LAB_NODE" "$LAB_PEER"; do
  if [ "$node" = "$LAB_NODE" ]; then
    if [ -x "$INVENTORY/orainstRoot.sh" ]; then
      "$INVENTORY/orainstRoot.sh" >> "$LOG" 2>&1 || warn "orainstRoot.sh reported a problem on $node"
      info "orainstRoot.sh done on $node"
    fi
  else
    if ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" "test -x '$INVENTORY/orainstRoot.sh'" 2>/dev/null; then
      ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" "'$INVENTORY/orainstRoot.sh'" >> "$LOG" 2>&1 \
        || warn "orainstRoot.sh reported a problem on $node"
      info "orainstRoot.sh done on $node"
    fi
  fi
done

# 2. root.sh on node 1: this creates the cluster and also creates and mounts the
#    OCR disk group, so it is the long one (10-20 minutes).
if [ -f "$GRID_HOME/install/root_${LAB_NODE}.log" ] && \
   grep -q "Successfully configured" "$GRID_HOME/install/root_${LAB_NODE}.log" 2>/dev/null; then
  info "root.sh already completed on $LAB_NODE"
else
  log "root.sh on $LAB_NODE (establishes the cluster and the OCR disk group)"
  if ! printf '\n\n\n\n' | "$GRID_HOME/root.sh" >> "$LOG" 2>&1; then
    warn "root.sh on $LAB_NODE returned an error, see $GRID_HOME/install/root_${LAB_NODE}.log"
    tail -n 30 "$LOG" >&2
    die "the cluster did not configure on $LAB_NODE"
  fi
  info "root.sh completed on $LAB_NODE"
fi

# 3. root.sh on node 2, only once the cluster exists.
log "root.sh on $LAB_PEER (joins it to the cluster)"
if ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" \
     "test -f $GRID_HOME/install/root_$LAB_PEER.log && grep -q 'Successfully configured' $GRID_HOME/install/root_$LAB_PEER.log" 2>/dev/null; then
  info "root.sh already completed on $LAB_PEER"
else
  if ! ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" \
        "printf '\n\n\n\n' | $GRID_HOME/root.sh > /var/tmp/root_peer.log 2>&1"; then
    ssh -o BatchMode=yes "root@$LAB_PEER_PUB_IP" "tail -n 30 /var/tmp/root_peer.log" >&2 || true
    die "root.sh failed on $LAB_PEER"
  fi
  info "root.sh completed on $LAB_PEER"
fi

log "Cluster state"
su - grid -c "$GRID_HOME/bin/crsctl check cluster -all" 2>&1 | sed 's/^/    /' || true
su - grid -c "$GRID_HOME/bin/crsctl stat res -t" 2>&1 | sed 's/^/    /' | head -25 || true

mark_done grid_install
log "Grid Infrastructure is running on $LAB_CLUSTER_NAME"
