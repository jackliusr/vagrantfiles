#!/usr/bin/env bash
# 01-base.sh - turns a VM into a RAC node: accounts and groups, kernel and shell
# limits, SSH trust between the nodes, the three lab networks, DNS for SCAN and
# the service/OS settings Grid Infrastructure insists on.
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
: "${LAB_STORAGE_NODE_IP:?LAB_STORAGE_NODE_IP is not set}"
: "${LAB_VIP:?LAB_VIP is not set}"
: "${LAB_PEER_PRIV_IP:?LAB_PEER_PRIV_IP is not set}"
: "${LAB_PEER_PUB_IP:?LAB_PEER_PUB_IP is not set}"
: "${LAB_PEER_VIP:?LAB_PEER_VIP is not set}"
: "${LAB_PRIV_MAC:?LAB_PRIV_MAC is not set}"
: "${LAB_PUB_MAC:?LAB_PUB_MAC is not set}"
: "${LAB_STORAGE_MAC:?LAB_STORAGE_MAC is not set}"

log "Preparing RAC node $LAB_NODE"

log "Setting the hostname"
hostnamectl set-hostname "$LAB_NODE"

# SCAN is deliberately absent: Grid Infrastructure refuses to install when the
# SCAN name resolves from /etc/hosts, because a real cluster must get it from
# DNS. The dnsmasq instance on the host serves it (host/scan-dns.sh).
log "Writing name resolution for the cluster nodes"
HOSTS_BEGIN="# BEGIN rac-lab"
HOSTS_END="# END rac-lab"
sed -i "/^${HOSTS_BEGIN}$/,/^${HOSTS_END}$/d" /etc/hosts

# The box ships a Debian-style "127.0.1.1 <hostname>" line. Grid Infrastructure
# resolves the node names itself and a loopback answer makes it fail, so any
# loopback mapping for our own names is removed.
sed -i -E "/^127\.[0-9.]+[[:space:]]+.*\b(${LAB_NODE}|${LAB_PEER})\b/d" /etc/hosts
{
  echo "$HOSTS_BEGIN"
  printf '%s %s %s.localdomain\n' "$LAB_PUB_IP"  "$LAB_NODE" "$LAB_NODE"
  printf '%s %s %s.localdomain\n' "$LAB_PEER_PUB_IP" "$LAB_PEER" "$LAB_PEER"
  printf '%s %s-priv\n' "$LAB_PRIV_IP" "$LAB_NODE"
  printf '%s %s-priv\n' "$LAB_PEER_PRIV_IP" "$LAB_PEER"
  printf '%s %s-vip\n' "$LAB_VIP" "$LAB_NODE"
  printf '%s %s-vip\n' "$LAB_PEER_VIP" "$LAB_PEER"
  echo "$HOSTS_END"
} >> /etc/hosts
info "$LAB_NODE $LAB_PUB_IP, $LAB_PEER $LAB_PEER_PUB_IP"
info "SCAN ($LAB_SCAN_NAME) is resolved by DNS, not /etc/hosts"

log "Relaxing SELinux and disabling the packet filter"
# A RAC node opens a large, version-dependent set of ports between the nodes
# (CRS, CSS, ASM, GIPC). The lab bridges are isolated, so the firewall is off.
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
systemctl disable --now firewalld >/dev/null 2>&1 || true
info "SELinux permissive, firewalld disabled"

log "Installing the Oracle and cluster prerequisites"
# oracle-database-preinstall-19c brings the account, kernel parameters, limits
# and most packages; the rest are what the Grid Infrastructure installer checks
# for on top of that.
if ! rpm -q oracle-database-preinstall-19c >/dev/null 2>&1; then
  dnf install -y oracle-database-preinstall-19c >/dev/null || die "could not install oracle-database-preinstall-19c"
fi
pkgs="iscsi-initiator-utils sg3_utils unzip bc ksh make gcc glibc-devel \
      libaio-devel libstdc++-devel elfutils-libelf-devel sysstat smartmontools \
      net-tools chrony lvm2 tar xz"
# shellcheck disable=SC2086
dnf install -y $pkgs >/dev/null || warn "some prerequisite packages failed to install"

# The preinstall package creates oinstall/dba/oper/backupdba/dgdba/kmdba/racdba
# and the oracle user. Grid Infrastructure adds the ASM groups and its own user.
log "Creating the grid and oracle accounts"
# The preinstall package already used 54321-54330 for its own groups, so these
# ids are picked from a free range. GI compares the group ids of both nodes, and
# both nodes run this script, so the same ids end up on each.
next_free_gid() {
  local gid=$1
  while getent group "$gid" >/dev/null; do
    gid=$((gid + 1))
  done
  printf '%s' "$gid"
}

for group in asmadmin asmoper asmdba; do
  if ! getent group "$group" >/dev/null; then
    gid=$(next_free_gid 54340)
    groupadd -g "$gid" "$group" || die "cannot create group $group"
    info "$group created with gid $gid"
  fi
done

if ! getent passwd grid >/dev/null; then
  useradd -u "$(next_free_gid 54360)" -g oinstall -G asmadmin,asmdba,asmoper,dba \
    -c "Oracle Grid Infrastructure owner" -m -s /bin/bash grid \
    || die "cannot create the grid user"
fi
# The oracle user must be able to touch ASM, which means asmdba.
usermod -aG asmdba,asmoper,asmadmin oracle

# GI compares the OS groups of both nodes during the install, so the ids have to
# match exactly. The preinstall package uses fixed ids, which these are.
info "oinstall=$(getent group oinstall | cut -d: -f3) dba=$(getent group dba | cut -d: -f3) asmadmin=$(getent group asmadmin | cut -d: -f3)"
info "grid=$(id -u grid) oracle=$(id -u oracle)"

log "Configuring kernel parameters and shell limits for Grid Infrastructure"
cat > /etc/sysctl.d/99-rac-lab.conf <<'EOF'
# Grid Infrastructure and two instances on one node.
kernel.shmmax = 4398046511104
kernel.shmall = 1073741824
kernel.shmmni = 4096
kernel.sem = 250 32000 100 128
fs.aio-max-nr = 1048576
fs.file-max = 6815744
net.ipv4.ip_local_port_range = 9000 65499
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 16384 4194304
vm.swappiness = 10
vm.dirty_background_ratio = 3
vm.dirty_ratio = 80
EOF
sysctl --system >/dev/null 2>&1 || warn "some sysctl settings were rejected"

cat > /etc/security/limits.d/99-rac-lab.conf <<'EOF'
grid     soft   nofile    65536
grid     hard   nofile    16384
grid     soft   nproc     16384
grid     hard   nproc     16384
grid     soft   stack     10240
grid     hard   stack     32768
grid     soft   memlock   134217728
grid     hard   memlock   134217728
oracle   soft   nofile    65536
oracle   hard   nofile    16384
oracle   soft   nproc     16384
oracle   hard   nproc     16384
oracle   soft   stack     10240
oracle   hard   stack     32768
oracle   soft   memlock   134217728
oracle   hard   memlock   134217728
EOF

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

log "Configuring the private, public and storage interfaces"
LAB_PRIV_NIC=$(configure_nic "$LAB_PRIV_MAC" "$LAB_PRIV_IP" priv)
LAB_PUB_NIC=$(configure_nic "$LAB_PUB_MAC" "$LAB_PUB_IP" pub)
LAB_STORAGE_NIC=$(configure_nic "$LAB_STORAGE_MAC" "$LAB_STORAGE_NODE_IP" storage)
if [ "$LAB_PRIV_NIC" = "$LAB_PUB_NIC" ] || [ "$LAB_PRIV_NIC" = "$LAB_STORAGE_NIC" ] \
   || [ "$LAB_PUB_NIC" = "$LAB_STORAGE_NIC" ]; then
  die "the three lab networks must use different interfaces"
fi

# SCAN comes from the dnsmasq instance on the host, so the cluster resolves it
# through DNS the way a production cluster does, not from /etc/hosts (which GI
# rejects). NetworkManager is told to leave resolv.conf alone and the file is
# written here, so the order of servers is deterministic: the lab DNS first, the
# libvirt gateway as a fallback so package installs keep working without it.
log "Pointing DNS at the SCAN server ($LAB_DNS_IP)"
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-rac-lab-dns.conf <<'EOF'
[main]
# 01-base.sh writes /etc/resolv.conf itself: the SCAN server has to be the first
# resolver on every node, and NM would otherwise merge in the DHCP servers.
dns=none
EOF

cat > /etc/resolv.conf <<EOF
# Written by 01-base.sh - the lab DNS server answers for SCAN, and forwards
# everything else. The libvirt gateway is a fallback for when it is not running.
search lab localdomain
nameserver $LAB_DNS_IP
# Everything outside the lab zone is answered by the libvirt gateway, which
# forwards to the host's resolver: the lab DNS server only serves SCAN.
nameserver 192.168.121.1
options timeout:2 attempts:2
EOF
chmod 0644 /etc/resolv.conf
systemctl reload NetworkManager >/dev/null 2>&1 || systemctl restart NetworkManager >/dev/null 2>&1 || true

if getent hosts "$LAB_SCAN_NAME" >/dev/null 2>&1; then
  info "SCAN $LAB_SCAN_NAME resolves to: $(getent hosts "$LAB_SCAN_NAME" | awk '{print $1}' | tr '\n' ' ')"
else
  warn "SCAN $LAB_SCAN_NAME does not resolve yet - publish it on the host:"
  warn "  sudo ./host/scan-dns.sh setup"
fi

log "Disabling reverse DNS lookups in sshd"
# Every SSH into a node otherwise waits for a reverse lookup of the lab address
# to time out. Grid Infrastructure runs hundreds of SSH commands during setup and
# its file-attribute checks are timing-sensitive, so "UseDNS no" is not just a
# speed-up here: Oracle recommends it for RAC nodes.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-rac-lab.conf <<'EOF'
# Written by 01-base.sh for the RAC lab.
UseDNS no
EOF
if sshd -t 2>/dev/null; then
  systemctl reload sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  info "sshd reloaded with UseDNS no"
else
  rm -f /etc/ssh/sshd_config.d/99-rac-lab.conf
  warn "sshd rejected the drop-in, it was removed"
fi

log "Fixing scp for Grid Infrastructure"
# Oracle's installer (cvu) builds scp command lines with single-quoted remote
# paths and executes them directly, without a shell. OpenSSH 8.0's scp keeps the
# quote characters in the source path it uses for the filename match, so every
# copy-back from a peer fails with "protocol error: filename does not match
# request" even though the remote file exists. A thin wrapper strips the quotes
# before the real scp sees them, which is exactly what the shell would have done.
install_dequoted_scp() {
  if [ ! -e /usr/bin/scp.orig ]; then
    cp -a /usr/bin/scp /usr/bin/scp.orig
  fi
  cat > /usr/bin/scp <<'SCPWRAP'
#!/bin/bash
# Installed by 01-base.sh: strip the single quotes the Grid Infrastructure
# installer embeds in scp arguments (it execs scp without a shell).
args=()
for a in "$@"; do
  args+=("$(printf '%s' "$a" | tr -d "'")")
done
exec /usr/bin/scp.orig "${args[@]}"
SCPWRAP
  chmod 0755 /usr/bin/scp
  info "installed /usr/bin/scp wrapper (original kept as scp.orig)"
}
install_dequoted_scp

log "Setting up SSH trust between the nodes"
# Both nodes already trust one key: .runtime/lab_root_key, which the Vagrantfile
# generates and uploads. It is used to bootstrap everything else, because at this
# point neither node knows the other's key yet - authenticating with a per-node
# key that the peer has never seen is what makes the naive version of this hang.
SHARED_KEY=/root/.ssh/lab_root_key
install -d -m 0700 /root/.ssh
install -m 0600 /home/vagrant/rac-lab/lab_root_key "$SHARED_KEY"
SHARED_PUB=$(ssh-keygen -y -f "$SHARED_KEY") || die "cannot read the shared lab key"

# Both nodes run this at the same time, so nothing may truncate the file: keys are
# appended and then de-duplicated, which converges no matter who writes last.
add_key_locally() {
  local user=$1 key=$2 home group
  home=$(getent passwd "$user" | cut -d: -f6)
  group=$(id -gn "$user")
  install -d -m 0700 -o "$user" -g "$group" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  printf '%s\n%s\n' "$key" "$SHARED_PUB" >> "$home/.ssh/authorized_keys"
  sort -u -o "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys"
  chown "$user:$group" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
}

add_key_remotely() {
  local user=$1 key=$2
  printf '%s\n%s\n' "$key" "$SHARED_PUB" |
    ssh -i "$SHARED_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 "root@$LAB_PEER_PUB_IP" \
      "umask 077
       home=\$(getent passwd $user | cut -d: -f6)
       group=\$(id -gn $user)
       install -d -m 0700 -o $user -g \$group \"\$home/.ssh\"
       cat >> \"\$home/.ssh/authorized_keys\"
       sort -u -o \"\$home/.ssh/authorized_keys\" \"\$home/.ssh/authorized_keys\"
       chown $user:\$group \"\$home/.ssh/authorized_keys\"
       chmod 0600 \"\$home/.ssh/authorized_keys\""
}

# The shared key is the only credential both nodes have before this step, so a
# login with it is the one non-circular way to tell that the peer is ready. Both
# nodes provision in parallel and the package installation above takes minutes on
# one of them, hence the generous budget.
shared_login() {
  ssh -i "$SHARED_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 "root@$LAB_PEER_PUB_IP" true 2>/dev/null
}
log "Waiting for $LAB_PEER to trust the shared lab key"
wait_until 600 "$LAB_PEER to accept the shared lab key" shared_login \
  || die "the shared lab key is not trusted on $LAB_PEER; is its base step running?"

for user in root grid oracle; do
  home_for_user=$(getent passwd "$user" | cut -d: -f6)
  group_for_user=$(id -gn "$user")

  if [ ! -f "$home_for_user/.ssh/id_rsa" ]; then
    su - "$user" -c "ssh-keygen -q -t rsa -b 2048 -N '' -f \$HOME/.ssh/id_rsa" >/dev/null
  fi
  key=$(cat "$home_for_user/.ssh/id_rsa.pub")

  add_key_locally "$user" "$key"
  info "$user: own key and the shared key trusted locally"

  # sshd on the peer needs a moment to come up when both nodes start together.
  ok=false
  for attempt in $(seq 1 20); do
    if add_key_remotely "$user" "$key" 2>/dev/null; then
      ok=true
      break
    fi
    sleep 5
  done
  [ "$ok" = true ] || die "could not install the $user key on $LAB_PEER"
  info "$user: key installed on $LAB_PEER"
done

# Grid Infrastructure does not just need the keys: it runs "ssh <node> date" and
# treats an unknown host key as a failure, and it checks the local node too. The
# host keys are therefore pre-seeded for every name the installers use.
log "Seeding known_hosts for the cluster names"
for user in root grid oracle; do
  home_for_user=$(getent passwd "$user" | cut -d: -f6)
  group_for_user=$(id -gn "$user")
  install -d -m 0700 -o "$user" -g "$group_for_user" "$home_for_user/.ssh"
  : > "$home_for_user/.ssh/known_hosts"
  for name in "$LAB_NODE" "$LAB_PEER" "$LAB_NODE-priv" "$LAB_PEER-priv" \
              "$LAB_PRIV_IP" "$LAB_PEER_PRIV_IP" "$LAB_PUB_IP" "$LAB_PEER_PUB_IP"; do
    ssh-keyscan -T 5 -H "$name" 2>/dev/null >> "$home_for_user/.ssh/known_hosts" || true
  done
  chown "$user:$group_for_user" "$home_for_user/.ssh/known_hosts"
  chmod 0600 "$home_for_user/.ssh/known_hosts"
  info "$user: $(grep -c . "$home_for_user/.ssh/known_hosts") host keys known"
done

log "Verifying passwordless SSH to the peer"
for user in root grid oracle; do
  # No StrictHostKeyChecking here: the point is to prove that the seeded
  # known_hosts is what makes the login work, exactly as GI will use it.
  if su - "$user" -c "ssh -o BatchMode=yes -o ConnectTimeout=10 $LAB_PEER true" >/dev/null 2>&1 &&
     su - "$user" -c "ssh -o BatchMode=yes -o ConnectTimeout=10 $LAB_NODE true" >/dev/null 2>&1; then
    info "$user -> $LAB_PEER and $LAB_NODE: ok"
  else
    su - "$user" -c "ssh -o BatchMode=yes -o ConnectTimeout=10 $LAB_PEER true" 2>&1 | tail -2 >&2
    die "$user cannot ssh to $LAB_PEER or to $LAB_NODE itself"
  fi
done

# There is no NTP source in this lab, so Cluster Time Synchronisation Service
# (CTSS) is used: GI keeps the nodes in step with each other. chrony must not be
# running for CTSS to be selected.
log "Leaving time synchronisation to CTSS"
systemctl disable --now chronyd >/dev/null 2>&1 || true
info "chronyd disabled; GI will configure CTSS"

export LAB_PRIV_NIC LAB_PUB_NIC LAB_STORAGE_NIC
save_lab_env
mark_done base
log "Node $LAB_NODE prepared"
