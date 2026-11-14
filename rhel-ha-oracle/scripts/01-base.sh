#!/usr/bin/env bash
# 01-base.sh - common preparation for both cluster nodes: name resolution,
# SELinux/firewall, cluster packages, static addresses on the cluster and
# client networks, the hacluster account used by pcs and root SSH trust.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_CLUSTER_NAME:?LAB_CLUSTER_NAME is not set}"
: "${LAB_ORACLE_SID:?LAB_ORACLE_SID is not set}"
: "${LAB_CLUSTER_IP:?LAB_CLUSTER_IP is not set}"
: "${LAB_PEER_CLUSTER_IP:?LAB_PEER_CLUSTER_IP is not set}"
: "${LAB_CLIENT_IP:?LAB_CLIENT_IP is not set}"
: "${LAB_PEER_CLIENT_IP:?LAB_PEER_CLIENT_IP is not set}"
: "${LAB_SERVICE_IP:?LAB_SERVICE_IP is not set}"
: "${LAB_CLUSTER_MAC:?LAB_CLUSTER_MAC is not set}"
: "${LAB_CLIENT_MAC:?LAB_CLIENT_MAC is not set}"
: "${LAB_HACLUSTER_PASS:?LAB_HACLUSTER_PASS is not set}"

log "Preparing $LAB_NODE ($LAB_ROLE)"

log "Setting hostname and cluster name resolution"
hostnamectl set-hostname "$LAB_NODE"

HOSTS_BEGIN="# BEGIN rhel-ha-lab"
HOSTS_END="# END rhel-ha-lab"
sed -i "/^${HOSTS_BEGIN}$/,/^${HOSTS_END}$/d" /etc/hosts
{
  echo "$HOSTS_BEGIN"
  printf '%s %s\n%s %s\n' \
    "$LAB_CLIENT_IP" "$LAB_NODE" \
    "$LAB_PEER_CLIENT_IP" "$LAB_PEER" \
    | sort -k2 | awk '{ printf "%-16s %s\n", $1, $2 }'
  echo "$HOSTS_END"
} >> /etc/hosts
getent hosts "$LAB_PEER" >/dev/null || die "$LAB_PEER does not resolve"

log "Adjusting SELinux (permissive for the lab)"
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
setenforce 0 2>/dev/null || true

log "Enabling the repository that ships the High Availability packages"
# pcs/pacemaker/corosync/resource-agents live in the "addons" repository, which
# the generic Oracle Linux boxes leave disabled.
for repo_file in /etc/yum.repos.d/oracle-linux-ol*.repo; do
  [ -f "$repo_file" ] || continue
  sed -i -e '/^\[ol8_addons\]/,/^\[/ s/^enabled=0/enabled=1/' \
         -e '/^\[ol9_addons\]/,/^\[/ s/^enabled=0/enabled=1/' "$repo_file"
done
dnf makecache >/dev/null 2>&1 || true

log "Installing the high availability and storage packages"
dnf install -y --setopt=install_weak_deps=False \
  pcs pacemaker corosync resource-agents fence-agents-all sbd \
  lvm2 iscsi-initiator-utils sg3_utils \
  chrony tar unzip rsync psmisc vim-enhanced net-tools bind-utils \
  openssh-server openssh-clients \
  >/dev/null || die "dnf could not install the cluster packages (check 'dnf repolist')"
# The cluster stack pulls openssl-libs from the current OL9 update. The box
# ships an older openssh built against OpenSSL 3.0, so openssh is upgraded in
# the same transaction; otherwise the new sshd binary cannot load libcrypto.

systemctl enable --now chronyd >/dev/null 2>&1 || warn "chronyd could not be started"
timedatectl set-timezone UTC

log "Opening the ports Pacemaker, Corosync and pcsd need"
if systemctl is-active firewalld >/dev/null 2>&1; then
  if ! firewall-cmd --permanent --add-service=high-availability >/dev/null 2>&1; then
    warn "the firewalld high-availability service is not defined, opening ports manually"
    for port in 2224/tcp 3121/tcp 5405/udp 21064/tcp; do
      firewall-cmd --permanent --add-port="$port" >/dev/null
    done
  fi
  # Oracle listener
  firewall-cmd --permanent --add-port=1521/tcp >/dev/null
  firewall-cmd --reload >/dev/null
else
  info "firewalld is not running"
fi

log "Configuring the cluster and client networks"
nic_for_mac() {
  local wanted=${1,,} dev
  for dev in /sys/class/net/*; do
    [ -e "$dev/address" ] || continue
    if [ "$(tr -d '\n' < "$dev/address")" = "$wanted" ]; then
      basename "$dev"
      return 0
    fi
  done
  return 1
}

configure_nic() {
  local mac=${1,,} address=$2 role=$3 dev conn
  dev=$(nic_for_mac "$mac") || die "no interface with MAC $mac ($role)"
  conn=$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null || true)
  if [ -z "$conn" ] || [ "$conn" = "--" ]; then
    nmcli connection add type ethernet ifname "$dev" con-name "ha-$role" \
      ipv4.method manual ipv4.addresses "$address/24" \
      ipv4.never-default yes ipv6.method disabled connection.autoconnect yes >/dev/null
    nmcli connection up "ha-$role" >/dev/null
  else
    nmcli connection modify "$conn" \
      ipv4.method manual ipv4.addresses "$address/24" \
      ipv4.never-default yes ipv6.method disabled connection.autoconnect yes
    nmcli connection up "$conn" >/dev/null
  fi
  # stderr, so that the caller can capture the interface name from stdout.
  info "$role: $dev = $address/24" >&2
  printf '%s\n' "$dev"
}

LAB_CLUSTER_NIC=$(configure_nic "$LAB_CLUSTER_MAC" "$LAB_CLUSTER_IP" cluster)
LAB_CLIENT_NIC=$(configure_nic "$LAB_CLIENT_MAC" "$LAB_CLIENT_IP" client)
[ "$LAB_CLUSTER_NIC" != "$LAB_CLIENT_NIC" ] || die "cluster and client networks must use different interfaces"

log "Adding a swap file"
if ! swapon --show 2>/dev/null | grep -q .; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile >/dev/null 2>&1 || warn "could not enable /swapfile"
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
  info "swap enabled"
else
  info "swap already configured"
fi

log "Configuring the LVM system ID used for cluster activation"
# LVM-activate's system_id mode moves the volume group between nodes by
# rewriting its system ID, which needs a local system ID on every node.
cat > /etc/lvm/lvmlocal.conf <<EOF
local {
    system_id = "$LAB_NODE"
}
EOF
if ! grep -qs 'system_id_source = "lvmlocal"' /etc/lvm/lvm.conf; then
  printf '\nglobal {\n    system_id_source = "lvmlocal"\n}\n' >> /etc/lvm/lvm.conf
fi

log "Preparing the hacluster account and pcsd"
echo "hacluster:$LAB_HACLUSTER_PASS" | chpasswd
enable_svc pcsd
start_svc pcsd
pcsd_ready=false
for _ in $(seq 1 30); do
  if pcs status >/dev/null 2>&1 || [ "$(systemctl is-active pcsd)" = "active" ]; then
    pcsd_ready=true
    break
  fi
  sleep 2
done
[ "$pcsd_ready" = true ] || die "pcsd did not start"
info "pcsd is running"

log "Loading the softdog watchdog used by SBD"
echo softdog > /etc/modules-load.d/sbd-watchdog.conf
modprobe softdog || warn "could not load softdog"
[ -e /dev/watchdog ] && info "/dev/watchdog is available" || warn "/dev/watchdog is missing"

log "Enabling root SSH with the key uploaded by Vagrant"
install -d -m 0700 /root/.ssh
install -d -m 0755 /etc/ssh/sshd_config.d
if ! grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
cat > /etc/ssh/sshd_config.d/99-ha-lab.conf <<'EOF'
PermitRootLogin yes
PubkeyAuthentication yes
EOF
if sshd -t 2>/dev/null; then
  systemctl restart sshd
  info "sshd restarted with the lab configuration"
else
  warn "sshd -t failed; keeping the running daemon (check the OpenSSL/openssh versions)"
fi

KEY_SRC=/home/vagrant/ha-lab/lab_root_key
if [ -f "$KEY_SRC" ]; then
  install -m 0600 "$KEY_SRC" /root/.ssh/id_ed25519
  ssh-keygen -y -f /root/.ssh/id_ed25519 > /root/.ssh/id_ed25519.pub \
    || die "the uploaded root key is not usable"
  chmod 0644 /root/.ssh/id_ed25519.pub
  touch /root/.ssh/authorized_keys
  chmod 0600 /root/.ssh/authorized_keys
  if ! grep -qF "$(cat /root/.ssh/id_ed25519.pub)" /root/.ssh/authorized_keys; then
    cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
  fi
  rm -f "$KEY_SRC"
else
  warn "$KEY_SRC is missing; root SSH between the nodes will not work"
fi

cat > /root/.ssh/config <<'EOF'
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
chmod 0600 /root/.ssh/config

save_lab_env
mark_done base

if peer_reachable; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$LAB_PEER_CLIENT_IP" true 2>/dev/null; then
    info "passwordless root SSH to $LAB_PEER works"
  else
    warn "$LAB_PEER is reachable but root SSH is not ready yet"
  fi
else
  info "$LAB_PEER is not reachable yet (expected during the first 'vagrant up')"
fi

log "Base preparation finished"
