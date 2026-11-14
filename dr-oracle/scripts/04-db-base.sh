#!/usr/bin/env bash
# 04-db-base.sh - common preparation for the two database hosts (db1, db2).
#
# Name resolution, the iSCSI initiator, the two lab interfaces (SAN fabric and
# client network) and a swap file. The database host at site A only ever sees
# the site A array; the one at site B only ever sees the site B array.
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
: "${LAB_SITE_ROLE:?LAB_SITE_ROLE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_PEER_APP_IP:?LAB_PEER_APP_IP is not set}"
: "${LAB_PEER_SAN_IP:?LAB_PEER_SAN_IP is not set}"
: "${LAB_SAN_IP:?LAB_SAN_IP is not set}"
: "${LAB_DB_SAN_IP:?LAB_DB_SAN_IP is not set}"
: "${LAB_APP_IP:?LAB_APP_IP is not set}"
: "${LAB_SAN_MAC:?LAB_SAN_MAC is not set}"
: "${LAB_APP_MAC:?LAB_APP_MAC is not set}"

log "Preparing database host $LAB_NODE (site $LAB_SITE, $LAB_SITE_ROLE)"

log "Setting hostname and name resolution"
hostnamectl set-hostname "$LAB_NODE"
HOSTS_BEGIN="# BEGIN dr-lab"
HOSTS_END="# END dr-lab"
sed -i "/^${HOSTS_BEGIN}$/,/^${HOSTS_END}$/d" /etc/hosts
{
  echo "$HOSTS_BEGIN"
  printf '%s %s\n' "$LAB_APP_IP" "$LAB_NODE"
  printf '%s %s\n' "$LAB_PEER_APP_IP" "$LAB_PEER"
  printf '%s san-%s\n' "$LAB_SAN_IP" "$LAB_SITE"
  printf '%s %s-san\n' "$LAB_DB_SAN_IP" "$LAB_NODE"
  echo "$HOSTS_END"
} >> /etc/hosts

log "Relaxing SELinux and allowing the management network through the firewall"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
if systemctl is-active firewalld >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

log "Installing the iSCSI initiator tools"
for pkg in iscsi-initiator-utils sg3_utils iputils; do
  rpm -q "$pkg" >/dev/null 2>&1 || dnf install -y "$pkg" >/dev/null || die "could not install $pkg"
done

# A stable initiator name makes the array side predictable; the export itself
# runs in demo mode, so this is for readability rather than for access control.
cat > /etc/iscsi/initiatorname.iscsi <<EOF
InitiatorName=iqn.2026-11.lab.dr:$LAB_NODE
EOF
systemctl enable --now iscsid >/dev/null 2>&1 || die "could not start iscsid"
info "initiator name iqn.2026-11.lab.dr:$LAB_NODE"

log "Configuring the SAN fabric and client interfaces"
LAB_SAN_NIC=$(configure_nic "$LAB_SAN_MAC" "$LAB_DB_SAN_IP" san)
LAB_APP_NIC=$(configure_nic "$LAB_APP_MAC" "$LAB_APP_IP" app)
[ "$LAB_SAN_NIC" != "$LAB_APP_NIC" ] || die "the SAN and client networks must use different interfaces"

log "Adding a swap file"
if ! swapon --show 2>/dev/null | grep -q .; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
  info "2 GB swap enabled"
fi

export LAB_SAN_NIC LAB_APP_NIC
save_lab_env
mark_done db_base
log "Database host $LAB_NODE prepared"
