#!/usr/bin/env bash
# 06-vcs-install.sh - installs InfoScale Availability (VCS) on this node and
# brings up LLT and GAB.
#
# The Veritas installer is driven by a response file and installs the local
# node only; the cluster itself is built in 07-vcs-config.sh once both nodes
# are running. Without installer media the script explains what is missing and
# exits successfully.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Vagrant copies the scripts to the guest under /home/vagrant/vcs-lab, which is
# also where ./lab invokes them from; keep a fallback for ad-hoc copies.
if [ ! -r "$SCRIPT_DIR/lib.sh" ]; then
  SCRIPT_DIR=/home/vagrant/vcs-lab/scripts
fi
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
load_lab_env

: "${LAB_NODE:?LAB_NODE is not set}"
: "${LAB_PEER:?LAB_PEER is not set}"
: "${LAB_CLUSTER_ID:?LAB_CLUSTER_ID is not set}"

LAB_SOFTWARE_DIR=${LAB_SOFTWARE_DIR:-/home/vagrant/vcs-lab/software}
MOUNT_DIR=/mnt/infoscale
STAGE_DIR=/var/tmp/infoscale
RESPONSE_FILE=/var/tmp/infoscale-install.rsp
INSTALL_LOG=/var/tmp/infoscale-install.log

if [ ! -d "$LAB_SOFTWARE_DIR" ]; then
  warn "media directory $LAB_SOFTWARE_DIR does not exist"
  info "create software/ on the host, drop the InfoScale download in it and re-run:"
  info "  vagrant up --provision   (or: vagrant provision $LAB_NODE --provision-with vcs_install)"
  exit 0
fi

find_media_dir() {
  local candidate
  for candidate in "$LAB_SOFTWARE_DIR"/InfoScale* "$LAB_SOFTWARE_DIR"/*/; do
    if [ -x "$candidate/installer" ]; then
      printf '%s\n' "${candidate%/}"
      return 0
    fi
  done
  return 1
}

media_dir=$(find_media_dir || true)
media_name=""

if [ -z "$media_dir" ]; then
  tarball=$(find "$LAB_SOFTWARE_DIR" -maxdepth 1 -type f \
              \( -name 'VCS_InfoScale_*Linux*.tar.gz' -o -name 'InfoScale_Availability*.tar.gz' \) \
              | sort | head -n 1)
  iso=$(find "$LAB_SOFTWARE_DIR" -maxdepth 1 -type f \
          -name 'InfoScale*Linux*.iso' | sort | head -n 1)

  if [ -n "$tarball" ]; then
    media_name=$(basename "$tarball")
    log "Unpacking $tarball"
    install -d -m 0755 "$STAGE_DIR"
    tar -xzf "$tarball" -C "$STAGE_DIR"
    media_dir=$(find "$STAGE_DIR" -maxdepth 2 -type f -name installer -printf '%h\n' | head -n 1)
  elif [ -n "$iso" ]; then
    media_name=$(basename "$iso")
    log "Mounting $iso"
    install -d -m 0755 "$MOUNT_DIR"
    mountpoint -q "$MOUNT_DIR" || mount -o loop,ro "$iso" "$MOUNT_DIR"
    media_dir=$MOUNT_DIR
  fi
fi

if [ -z "$media_dir" ] || [ ! -x "$media_dir/installer" ]; then
  warn "no InfoScale Availability installer found in $LAB_SOFTWARE_DIR"
  info "expected one of:"
  info "  software/InfoScale_Availability_7.4.2/  (extracted download containing ./installer)"
  info "  software/VCS_InfoScale_Availability_7.4.2_Linux.tar.gz"
  info "  software/InfoScale_Availability_7.4.2_Linux.iso"
  info "then re-run: vagrant provision $LAB_NODE --provision-with vcs_install"
  exit 0
fi
[ -n "$media_name" ] || media_name=$(basename "$media_dir")
info "installer media: $media_dir"

log "Installing the InfoScale platform packages"
dnf install -y --setopt=install_weak_deps=False \
  chrony ethtool binutils policycoreutils-python-utils ksh libgcc glibc \
  libstdc++ libnsl compat-openssl10 zlib kmod ed libacl ncurses-compat-libs \
  perl perl-Exporter perl-Socket policycoreutils \
  >/dev/null || die "could not install the InfoScale prerequisite packages"

if [ -f "$LAB_SOFTWARE_DIR/vxlic.key" ]; then
  install -m 0600 "$LAB_SOFTWARE_DIR/vxlic.key" /var/tmp/vxlic.key
  license_line='$CFG{keys}{licensefile} = [ "/var/tmp/vxlic.key" ];'
else
  license_line='# no license key supplied; VCS runs in evaluation mode'
  warn "no vxlic.key found in $LAB_SOFTWARE_DIR, VCS will run without a license"
fi

# The product tag follows the edition and version of the media, e.g.
# InfoScale_Enterprise_7.4.2 -> ENTERPRISE742. Foundation or Enterprise media
# is needed for the VxVM coordinator disk group used by I/O fencing.
product=${LAB_INFOSCALE_PRODUCT:-}
if [ -z "$product" ]; then
  edition=AVAILABILITY
  case "${media_name,,}" in
    *enterprise*) edition=ENTERPRISE ;;
    *foundation*) edition=FOUNDATION ;;
    *storage*)    edition=STORAGE ;;
  esac
  version=$(printf '%s' "$media_name" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | tr -d '.')
  product="${edition}${version:-742}"
fi
info "product tag: $product"

log "Running the InfoScale installer in response file mode"
cat > "$RESPONSE_FILE" <<EOF
our %CFG;

\$CFG{accepteula} = 1;
\$CFG{prod}       = "$product";
\$CFG{systems}    = [ qw($LAB_NODE) ];
\$CFG{opt}{install} = 1;
\$CFG{opt}{logpath} = "/opt/VRTS/install/logs";
$license_line
1;
EOF

if ! ( cd "$media_dir" && ./installer -responsefile "$RESPONSE_FILE" -noipc ) \
     > "$INSTALL_LOG" 2>&1; then
  tail -n 40 "$INSTALL_LOG" >&2
  die "the InfoScale installer failed, see $INSTALL_LOG"
fi

[ -x /opt/VRTSvcs/bin/hastart ] || die "VCS binaries are missing after the installation, see $INSTALL_LOG"

# The Oracle agent type definition has to be visible to the VCS configuration
# directory before main.cf can include it.
if [ -f /etc/VRTSagents/ha/conf/Oracle/OracleTypes.cf ] \
   && [ ! -f /etc/VRTSvcs/conf/config/OracleTypes.cf ]; then
  cp /etc/VRTSagents/ha/conf/Oracle/OracleTypes.cf /etc/VRTSvcs/conf/config/
fi

log "Configuring LLT and GAB on $LAB_NODE"
: "${LAB_LLT1_NIC:?LAB_LLT1_NIC is not set, run the base step first}"
: "${LAB_LLT2_NIC:?LAB_LLT2_NIC is not set, run the base step first}"

mac_of() { tr -d '\n' < "/sys/class/net/$1/address"; }

cat > /etc/llttab <<EOF
set-node $LAB_NODE
set-cluster $LAB_CLUSTER_ID
link $LAB_LLT1_NIC eth-$(mac_of "$LAB_LLT1_NIC") - ether - -
link $LAB_LLT2_NIC eth-$(mac_of "$LAB_LLT2_NIC") - ether - -
EOF

if [[ "$LAB_NODE" < "$LAB_PEER" ]]; then
  printf '0 %s\n1 %s\n' "$LAB_NODE" "$LAB_PEER" > /etc/llthosts
else
  printf '0 %s\n1 %s\n' "$LAB_PEER" "$LAB_NODE" > /etc/llthosts
fi
info "LLT host table: $(tr '\n' ' ' < /etc/llthosts)"

echo "/sbin/gabconfig -c -n2" > /etc/gabtab

for sysconfig in llt gab; do
  if [ -f "/etc/sysconfig/$sysconfig" ]; then
    upper=$(printf '%s' "$sysconfig" | tr '[:lower:]' '[:upper:]')
    sed -i "s/^${upper}_START=.*/${upper}_START=1/" "/etc/sysconfig/$sysconfig"
    grep -q "^${upper}_START=" "/etc/sysconfig/$sysconfig" \
      || echo "${upper}_START=1" >> "/etc/sysconfig/$sysconfig"
  fi
done

if ! systemctl cat llt >/dev/null 2>&1 && [ ! -x /etc/init.d/llt ]; then
  die "the LLT service is not installed; check the installer output in $INSTALL_LOG"
fi

log "Starting LLT and GAB"
enable_svc llt
enable_svc gab
restart_svc llt
sleep 2
restart_svc gab
sleep 3

/sbin/lltconfig >/dev/null || die "LLT is not running"
info "LLT links:"
/sbin/lltstat -n 2>&1 | sed 's/^/    /' || true
info "GAB membership:"
/sbin/gabconfig -a 2>&1 | sed 's/^/    /' || true

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$LAB_PEER_CLIENT_IP" true 2>/dev/null; then
  info "$LAB_PEER is not reachable yet; LLT/GAB will see it once both nodes are up"
fi

mark_done vcs_install
log "InfoScale Availability installed and LLT/GAB configured"
