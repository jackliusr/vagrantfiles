#!/usr/bin/env bash
# 04-asm.sh - creates the DATA and FRA disk groups.
#
# gridSetup.sh creates OCR as part of configuring the cluster (it holds the OCR
# and the voting files). DATA and FRA are created here, once, from the first
# node; ASM shares them with every instance that is started afterwards.
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

GRID_HOME=/u01/app/19.0.0/grid
ASM_DISCOVERY='/dev/asm-disk*'

if [ ! -x "$GRID_HOME/bin/asmca" ]; then
  warn "Grid Infrastructure is not installed yet (no $GRID_HOME/bin/asmca)"
  info "install it first: add the grid media to software/ and run ./lab grid"
  exit 0
fi

if [ "$LAB_NODE_NUMBER" != "1" ]; then
  info "the disk groups are created from node 1 only; nothing to do on $LAB_NODE"
  exit 0
fi

if ! su - grid -c "$GRID_HOME/bin/crsctl check cluster" >/dev/null 2>&1; then
  die "the cluster is not running - start it with ./lab start-grid and try again"
fi

# disk group, redundancy, disk list. EXTERNAL because a single LUN per group is
# what the lab has; a production DATA group would be NORMAL or HIGH across many
# LUNs on separate arrays.
create_disks() { echo "$*"; }

create_diskgroup() {
  local dg=$1 redundancy=$2 disks=$3
  if su - grid -c "export ORACLE_SID=+ASM1; $GRID_HOME/bin/asmcmd lsdg $dg" >/dev/null 2>&1; then
    info "disk group $dg already exists"
    return 0
  fi
  log "Creating disk group $dg ($redundancy) from $disks"
  local args="-silent -createDiskGroup -diskGroupName $dg -diskList $disks"
  args="$args -redundancy $redundancy -diskString '$ASM_DISCOVERY'"
  if ! su - grid -c "$GRID_HOME/bin/asmca $args"; then
    tail -n 20 "$GRID_HOME/cfgtoollogs/asmca/asmca-*.log" 2>/dev/null >&2 || true
    die "could not create disk group $dg"
  fi
  info "$dg created"
}

log "ASM state before the change"
su - grid -c "export ORACLE_SID=+ASM1; $GRID_HOME/bin/asmcmd lsdg" 2>&1 | sed 's/^/    /' || true

create_diskgroup DATA EXTERNAL /dev/asm-disk4
create_diskgroup FRA  EXTERNAL /dev/asm-disk5

log "ASM state after the change"
su - grid -c "export ORACLE_SID=+ASM1; $GRID_HOME/bin/asmcmd lsdg" 2>&1 | sed 's/^/    /'

log "ASM disks in use"
su - grid -c "export ORACLE_SID=+ASM1; $GRID_HOME/bin/asmcmd lsdsk --candidate --discovery" 2>&1 | sed 's/^/    /' || true

mark_done asm
log "ASM disk groups ready"
