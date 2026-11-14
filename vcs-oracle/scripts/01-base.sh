#!/usr/bin/env bash
# 01-base.sh - common OS preparation for both cluster nodes:
# hostname resolution, SELinux/firewall, base packages, static addresses on the
# cluster networks, root SSH trust and discovery of the interface names.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_CLIENT_IP:?LAB_CLIENT_IP is not set}"
: "${LAB_PEER_CLIENT_IP:?LAB_PEER_CLIENT_IP is not set}"
: "${LAB_LLT1_IP:?LAB_LLT1_IP is not set}"
: "${LAB_LLT2_IP:?LAB_LLT2_IP is not set}"
: "${LAB_SERVICE_IP:?LAB_SERVICE_IP is not set}"
: "${LAB_CLUSTER_NAME:?LAB_CLUSTER_NAME is not set}"
: "${LAB_ORACLE_SID:?LAB_ORACLE_SID is not set}"
: "${LAB_LLT1_MAC:?LAB_LLT1_MAC is not set}"
: "${LAB_LLT2_MAC:?LAB_LLT2_MAC is not set}"
: "${LAB_CLIENT_MAC:?LAB_CLIENT_MAC is not set}"

log "Preparing $LAB_NODE ($LAB_ROLE)"

log "Setting hostname and cluster name resolution"
hostnamectl set-hostname "$LAB_NODE"

HOSTS_BEGIN="# BEGIN vcs-lab"
HOSTS_END="# END vcs-lab"
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

log "Disabling SELinux and firewalld"
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
setenforce 0 2>/dev/null || true
for service in firewalld nftables iptables ip6tables; do
  systemctl disable --now "$service" >/dev/null 2>&1 || true
done

log "Configuring kernel parameters for LLT and Oracle"
cat > /etc/sysctl.d/90-vcs-lab.conf <<'EOF'
# LLT sends heartbeats over several links; loose reverse path filtering avoids
# dropping frames that arrive on the "wrong" link.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Veritas requires this: vxfen threads can wait long enough to trip the
# hung-task detector, and a panic there would reboot the node.
kernel.hung_task_panic = 0
EOF
sysctl --system >/dev/null

log "Installing base packages"
dnf install -y --setopt=install_weak_deps=False \
  lvm2 ksh net-tools bind-utils chrony tar unzip rsync psmisc vim-enhanced \
  iscsi-initiator-utils sg3_utils \
  >/dev/null || die "dnf could not install the base packages"

systemctl enable --now chronyd >/dev/null 2>&1 || warn "chronyd could not be started"
timedatectl set-timezone UTC

log "Configuring the cluster networks"
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
    nmcli connection add type ethernet ifname "$dev" con-name "vcs-$role" \
      ipv4.method manual ipv4.addresses "$address/24" \
      ipv4.never-default yes ipv6.method disabled connection.autoconnect yes >/dev/null
    nmcli connection up "vcs-$role" >/dev/null
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

LAB_LLT1_NIC=$(configure_nic "$LAB_LLT1_MAC" "$LAB_LLT1_IP" llt1)
LAB_LLT2_NIC=$(configure_nic "$LAB_LLT2_MAC" "$LAB_LLT2_IP" llt2)
LAB_CLIENT_NIC=$(configure_nic "$LAB_CLIENT_MAC" "$LAB_CLIENT_IP" client)

if [ "$LAB_CLIENT_NIC" = "$LAB_LLT1_NIC" ] || [ "$LAB_CLIENT_NIC" = "$LAB_LLT2_NIC" ] \
   || [ "$LAB_LLT1_NIC" = "$LAB_LLT2_NIC" ]; then
  die "LLT links and client network must use different interfaces"
fi

log "Enabling root SSH with the key uploaded by Vagrant"
install -d -m 0700 /root/.ssh
install -d -m 0755 /etc/ssh/sshd_config.d
# sshd keeps the first value it sees, so the drop-in directory has to be
# included before the rest of sshd_config.
if ! grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
cat > /etc/ssh/sshd_config.d/99-vcs-lab.conf <<'EOF'
PermitRootLogin yes
PubkeyAuthentication yes
EOF
sshd -t || die "invalid sshd configuration"
systemctl restart sshd

KEY_SRC=/home/vagrant/vcs-lab/lab_root_key
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
