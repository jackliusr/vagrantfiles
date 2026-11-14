#!/usr/bin/env bash
# 01-array.sh - turns a VM into a SAN array appliance (san1 or san2).
#
# The appliance plays the part of a mid-range array: two real block devices
# inside (vdb = data LUN, vdc = FRA/archive LUN), DRBD as the replication engine
# towards the other site, and targetcli as the iSCSI front end that the database
# host at the same site logs into (03-target.sh). The replication link between
# the two appliances gets a netem delay so that redo transport, DRBD lag and
# failover timing behave like a real WAN instead of a localhost memcpy.
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
: "${LAB_SITE:?LAB_SITE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_SAN_FE_IP:?LAB_SAN_FE_IP is not set}"
: "${LAB_PEER_SAN_FE_IP:?LAB_PEER_SAN_FE_IP is not set}"
: "${LAB_REPL_IP:?LAB_REPL_IP is not set}"
: "${LAB_PEER_REPL_IP:?LAB_PEER_REPL_IP is not set}"
: "${LAB_SAN_MAC:?LAB_SAN_MAC is not set}"
: "${LAB_REPL_MAC:?LAB_REPL_MAC is not set}"

log "Preparing array appliance $LAB_NODE (site $LAB_SITE)"

log "Setting hostname and name resolution"
hostnamectl set-hostname "$LAB_NODE"
HOSTS_BEGIN="# BEGIN dr-lab"
HOSTS_END="# END dr-lab"
sed -i "/^${HOSTS_BEGIN}$/,/^${HOSTS_END}$/d" /etc/hosts
{
  echo "$HOSTS_BEGIN"
  printf '%s %s\n' "$LAB_SAN_FE_IP" "$LAB_NODE"
  printf '%s %s\n' "$LAB_PEER_SAN_FE_IP" "$LAB_PEER"
  printf '%s %s-repl\n' "$LAB_REPL_IP" "$LAB_NODE"
  printf '%s %s-repl\n' "$LAB_PEER_REPL_IP" "$LAB_PEER"
  echo "$HOSTS_END"
} >> /etc/hosts

log "Relaxing SELinux (the array exports raw block devices)"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

log "Installing DRBD 9 and the iSCSI target"
# DRBD 9 is not in the Oracle Linux repositories; ELRepo builds the kmod with
# weak-modules support, so it links itself against whatever 8.x kernel the box
# boots even though the RPM was built for a newer one.
if ! rpm -q kmod-drbd90 >/dev/null 2>&1; then
  if ! rpm -q elrepo-release >/dev/null 2>&1; then
    dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm \
      >/dev/null || die "could not install the ELRepo release package"
  fi
  dnf install -y kmod-drbd90 drbd90-utils >/dev/null || die "could not install DRBD"
fi
rpm -q targetcli >/dev/null 2>&1 || dnf install -y targetcli >/dev/null || die "could not install targetcli"
# tc lives in iproute-tc on EL8, not in iproute, and the netem qdisc itself is in
# kernel-modules-extra.
rpm -q iproute-tc >/dev/null 2>&1 || dnf install -y iproute-tc >/dev/null || warn "could not install iproute-tc"
if ! modinfo -F filename sch_netem >/dev/null 2>&1; then
  dnf install -y "kernel-modules-extra-$(uname -r)" >/dev/null 2>&1 \
    || warn "could not install kernel-modules-extra"
fi
modprobe sch_netem 2>/dev/null \
  || warn "sch_netem is unavailable, the WAN latency emulation will be skipped"
echo "sch_netem" > /etc/modules-load.d/netem.conf

# Load at boot even before drbd.service runs, so /dev/drbdN exists when the
# iSCSI target restores its configuration.
echo "drbd" > /etc/modules-load.d/drbd.conf
modprobe drbd || die "the DRBD kernel module does not load on $(uname -r)"
drbd_version=$(awk '/^version:/ {print $2}' /proc/drbd)
[ -n "$drbd_version" ] || die "/proc/drbd is empty, the DRBD module did not initialise"
info "DRBD $drbd_version loaded on kernel $(uname -r)"
systemctl enable drbd.service >/dev/null 2>&1 || warn "could not enable drbd.service"

log "Configuring the SAN front-end and replication interfaces"
LAB_SAN_NIC=$(configure_nic "$LAB_SAN_MAC" "$LAB_SAN_FE_IP" san)
LAB_REPL_NIC=$(configure_nic "$LAB_REPL_MAC" "$LAB_REPL_IP" repl)
[ "$LAB_SAN_NIC" != "$LAB_REPL_NIC" ] || die "the SAN and replication networks must use different interfaces"

log "Checking the array's own block devices"
for dev in /dev/vdb /dev/vdc; do
  if [ -b "$dev" ]; then
    info "$dev: $(lsblk -dno SIZE "$dev" | tr -d ' ')"
  else
    warn "$dev is missing - re-create the VM so vagrant-libvirt attaches the array disks"
  fi
done

log "Emulating the WAN latency on $LAB_REPL_NIC"
WAN_DELAY=${LAB_WAN_DELAY:-5ms}
if [ "$WAN_DELAY" = "0" ] || [ "$WAN_DELAY" = "0ms" ]; then
  tc qdisc del dev "$LAB_REPL_NIC" root 2>/dev/null || true
  info "no delay configured"
else
  tc qdisc replace dev "$LAB_REPL_NIC" root netem delay "$WAN_DELAY" 1ms \
    || warn "could not install the netem qdisc"
  info "one-way delay $WAN_DELAY +-1ms (see ./lab wan)"
fi

export LAB_SAN_NIC LAB_REPL_NIC
save_lab_env
mark_done array
log "Array appliance $LAB_NODE ready"
