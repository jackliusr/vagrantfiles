#!/usr/bin/env bash
# 01-base.sh - turns a VM into a Ceph lab node: host name and name resolution for
# every node of the lab, the dedicated lab interface, SELinux and firewall
# settings, time synchronisation, the Ceph package repository, the container
# runtime cephadm deploys daemons with, and passwordless root SSH between the
# nodes.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/ceph-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_ROLE:?LAB_ROLE is not set}"
: "${LAB_IP:?LAB_IP is not set}"
: "${LAB_NIC_MAC:?LAB_NIC_MAC is not set}"
: "${LAB_PUBLIC_NETWORK:?LAB_PUBLIC_NETWORK is not set}"
: "${LAB_SERVERS:?LAB_SERVERS is not set}"
: "${LAB_CLIENT_NAME:?LAB_CLIENT_NAME is not set}"
: "${LAB_CLIENT_IP:?LAB_CLIENT_IP is not set}"
: "${LAB_CEPH_RELEASE:?LAB_CEPH_RELEASE is not set}"

log "Preparing Ceph node $LAB_NODE ($LAB_ROLE)"

log "Setting the host name"
hostnamectl set-hostname "$LAB_NODE"

# cephadm identifies hosts by the short host name and refuses to bootstrap a
# node whose name resolves to a loopback address. Both Vagrant and cloud-init
# like to add a "127.0.1.1 <name>" line, so any loopback mapping of a lab name
# is removed before the real mappings are written.
log "Writing name resolution for the lab nodes"
HOSTS_BEGIN="# BEGIN ceph-lab"
HOSTS_END="# END ceph-lab"
sed -i "/^${HOSTS_BEGIN}$/,/^${HOSTS_END}$/d" /etc/hosts
lab_names=$(lab_all_nodes | paste -sd'|' -)
sed -i -E "/^127\.[0-9.]+[[:space:]]+.*\b(${lab_names})\b/d" /etc/hosts
{
  echo "$HOSTS_BEGIN"
  for name in $(lab_all_nodes); do
    printf '%s %s\n' "$(node_ip "$name")" "$name"
  done
  echo "$HOSTS_END"
} >> /etc/hosts

self_resolved=$(getent hosts "$LAB_NODE" | awk 'NR == 1 { print $1 }' || true)
[ "$self_resolved" = "$LAB_IP" ] \
  || die "$LAB_NODE resolves to ${self_resolved:-nothing}, expected $LAB_IP (check /etc/hosts)"
info "$LAB_NODE = $self_resolved, hostname -f says $(hostname -f)"

log "Relaxing SELinux and disabling the packet filter"
# The lab bridge is isolated and cephadm needs a wide, release-dependent set of
# ports (3300, 6789, 6800-7300, 8443); the firewall is off instead of being
# opened piecemeal.
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
systemctl disable --now firewalld >/dev/null 2>&1 || true
info "SELinux permissive, firewalld disabled"

log "Tuning the kernel and the journal for a lab"
cat > /etc/sysctl.d/99-ceph-lab.conf <<'EOF'
vm.swappiness = 10
fs.file-max = 6815744
EOF
sysctl --system >/dev/null 2>&1 || warn "some sysctl settings were rejected"

install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-ceph-lab.conf <<'EOF'
[Journal]
# Monitors and OSDs are chatty, and the root disk is small.
SystemMaxUse=1G
EOF
systemctl restart systemd-journald >/dev/null 2>&1 || warn "could not restart systemd-journald"

log "Enabling time synchronisation"
# Monitors compare their clocks; the VMs share the host's clock, so chrony only
# has to stay out of the way and keep the drift from accumulating over a long
# running lab.
systemctl enable --now chronyd >/dev/null 2>&1 || warn "chronyd did not start"
chronyc -a makestep >/dev/null 2>&1 || true

log "Configuring the lab interface"
LAB_NIC=$(configure_nic "$LAB_NIC_MAC" "$LAB_IP" pub)

log "Enabling the Ceph $LAB_CEPH_RELEASE package repository"
# Oracle Linux reports itself as RHEL, which is what the Ceph packages are built
# for. The repository keeps its architecture and noarch packages apart, hence
# the two sections.
EL_VERSION=$(rpm -E %rhel 2>/dev/null || true)
case $EL_VERSION in
  '' | *[!0-9]*) EL_VERSION=$(. /etc/os-release && printf '%s' "${VERSION_ID%%.*}") ;;
esac
[ -n "$EL_VERSION" ] || die "cannot work out the EL major version"

LAB_CEPH_MIRROR=${LAB_CEPH_MIRROR:-https://download.ceph.com}
cat > /etc/yum.repos.d/ceph-lab.repo <<EOF
[ceph-lab]
name=Ceph $LAB_CEPH_RELEASE packages for \$basearch
baseurl=${LAB_CEPH_MIRROR%/}/rpm-${LAB_CEPH_RELEASE}/el${EL_VERSION}/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${LAB_CEPH_MIRROR%/}/keys/release.asc

[ceph-lab-noarch]
name=Ceph $LAB_CEPH_RELEASE noarch packages
baseurl=${LAB_CEPH_MIRROR%/}/rpm-${LAB_CEPH_RELEASE}/el${EL_VERSION}/noarch/
enabled=1
gpgcheck=1
gpgkey=${LAB_CEPH_MIRROR%/}/keys/release.asc
EOF
info "repository: $LAB_CEPH_MIRROR/rpm-$LAB_CEPH_RELEASE/el$EL_VERSION"
rpm --import "${LAB_CEPH_MIRROR%/}/keys/release.asc" \
  || rpm --import https://download.ceph.com/keys/release.asc \
  || die "could not import the Ceph signing key - is this VM online?"

log "Installing the Ceph packages for a $LAB_ROLE node"
# openssh is part of the transaction on purpose: the Ceph and container packages
# pull in a newer libcrypto than the base box's OpenSSH was built against, and
# sshd then refuses to start new sessions ("OpenSSL version mismatch"). Installing
# both in one transaction keeps the binaries and the library in step.
pkgs="ceph-common attr openssh openssh-clients openssh-server"
if [ "$LAB_ROLE" = server ]; then
  # cephadm deploys every daemon as a rootful podman container, and creates the
  # OSDs with ceph-volume, which needs LVM.
  pkgs="$pkgs cephadm podman lvm2 chrony sg3_utils"
else
  # The mount is a FUSE mount: libcephfs understands the aes256k cephx keys the
  # Squid monitors issue, while the 5.14 kernel client in this box only knows
  # aes-128 (see README.md).
  pkgs="$pkgs ceph-fuse"
fi
# shellcheck disable=SC2086
if ! dnf install -y $pkgs >/tmp/ceph-lab-dnf.log 2>&1; then
  tail -20 /tmp/ceph-lab-dnf.log >&2
  if grep -q '^Killed' /tmp/ceph-lab-dnf.log; then
    die "dnf was killed, almost certainly for memory: give the VM more RAM (CEPH_LAB_MEMORY)"
  fi
  die "package installation failed - check the network (CEPH_LAB_MIRROR) and that this VM is online"
fi
# || true: the client has no cephadm, and a failing command substitution would
# abort the script through set -e.
cephadm_version=$(cephadm version 2>/dev/null | awk '/^cephadm version/ { print $3 }' || true)
info "cephadm ${cephadm_version:-not installed} on $(. /etc/os-release && echo "$PRETTY_NAME")"

log "Setting up root SSH between the lab nodes"
install -d -m 0700 /root/.ssh
install -m 0600 /home/vagrant/ceph-lab/lab_root_key /root/.ssh/lab_root_key
lab_pub=$(ssh-keygen -y -f /root/.ssh/lab_root_key) || die "cannot read the shared lab key"
touch /root/.ssh/authorized_keys
grep -qxF "$lab_pub" /root/.ssh/authorized_keys || printf '%s\n' "$lab_pub" >> /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

SSH_BEGIN="# BEGIN ceph-lab"
SSH_END="# END ceph-lab"
touch /root/.ssh/config
chmod 0600 /root/.ssh/config
sed -i "/^${SSH_BEGIN}$/,/^${SSH_END}$/d" /root/.ssh/config
{
  echo "$SSH_BEGIN"
  printf 'Host %s\n' "$(lab_all_nodes | paste -sd' ' -)"
  echo "  IdentityFile /root/.ssh/lab_root_key"
  echo "  IdentitiesOnly yes"
  echo "  StrictHostKeyChecking accept-new"
  echo "  UserKnownHostsFile /root/.ssh/known_hosts"
  echo "$SSH_END"
} >> /root/.ssh/config

log "Disabling reverse DNS lookups in sshd"
# cephadm fans out SSH commands from the manager and the mons, and every login
# would otherwise wait for a reverse lookup of the lab address to time out.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-ceph-lab.conf <<'EOF'
# Written by 01-base.sh for the Ceph lab.
UseDNS no
EOF
if sshd -t 2>/dev/null; then
  systemctl reload sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  info "sshd reloaded with UseDNS no"
else
  rm -f /etc/ssh/sshd_config.d/99-ceph-lab.conf
  warn "sshd rejected the drop-in, it was removed"
fi

log "Verifying passwordless SSH to the other nodes"
# The nodes provision in parallel (./lab up uses --parallel), so a peer may
# still be installing packages. A single-node bring-up is a normal debugging
# flow, so this warns rather than fails; the cluster step is the real gate.
peer_deadline=$((SECONDS + 420))
for name in $(lab_all_nodes); do
  [ "$name" = "$LAB_NODE" ] && continue
  remaining=$((peer_deadline - SECONDS))
  if [ "$remaining" -gt 0 ] && wait_until "$remaining" "ssh to $name" lab_ssh "$name" true; then
    info "root@$name: ok"
  else
    warn "root@$name does not accept the lab key yet"
  fi
done

if [ "$LAB_ROLE" = server ]; then
  log "Looking for the OSD disks"
  # vagrant-libvirt appends the data disks after the root disk. Nothing is
  # prepared here: cephadm takes whole devices that are unused, unpartitioned
  # and unmounted, which is exactly what `lv.storage` creates.
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/    /'
  if [ "$(lsblk -dpno NAME | wc -l)" -lt 2 ]; then
    warn "only one whole disk found; OSDs need the extra disks from the Vagrantfile"
  fi
fi

export LAB_NIC
save_lab_env
mark_done base
log "Node $LAB_NODE prepared"
