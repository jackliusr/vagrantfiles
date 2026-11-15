#!/usr/bin/env bash
# host/scan-dns.sh - the DNS name the cluster needs for SCAN.
#
# Oracle's SCAN (Single Client Access Name) must resolve to the same set of
# addresses on every node, and Grid Infrastructure refuses to install when SCAN
# comes from /etc/hosts. Real clusters use corporate DNS; here the DNS server is
# the dnsmasq libvirt already runs for the lab's public network, which is the
# only resolver that can bind port 53 on that bridge anyway.
#
# Three A records make SCAN behave like the real thing: the resolver rotates the
# order it returns them in, which is what clients use for connect-time load
# balancing across the cluster.
#
# Usage: sudo ./host/scan-dns.sh setup|status|teardown
set -Eeuo pipefail

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NETWORK=${RAC_LAB_PUB_NETWORK:-rac-pub}
SCAN_NAME=${RAC_LAB_SCAN:-rac-scan.lab}
DOMAIN=${RAC_LAB_DOMAIN:-lab}
SCAN_IPS=${RAC_LAB_SCAN_IPS:-"10.40.2.110 10.40.2.111 10.40.2.112"}
DNS_IP=${RAC_LAB_DNS_IP:-10.40.2.1}
VAGRANT_NET=${RAC_LAB_VAGRANT_NETWORK:-192.168.121.1}
case $SCAN_NAME in
  *.*) FQDN=$SCAN_NAME ;;
  *)   FQDN="$SCAN_NAME.$DOMAIN" ;;
esac

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Reading the configuration needs no privileges (libvirt group membership is
# enough); changing it does.
if [ "${1:-setup}" != "status" ] && [ "$(id -u)" -ne 0 ]; then
  die "run this script with sudo"
fi
command -v virsh >/dev/null || die "virsh is not installed"

virsh_q() { virsh -c qemu:///system "$@"; }

network_exists() {
  virsh_q net-list --all --name 2>/dev/null | grep -qx "$NETWORK"
}

# Prints the host entries of the network's <dns> section as "ip name".
current_records() {
  virsh_q net-dumpxml "$NETWORK" 2>/dev/null | tr '>' '>\n' |
    awk '/<host ip=/{ match($0, /ip=.([0-9.]+)./, m); ip=m[1] }
         /<hostname>/{ gsub(/.*<hostname>|<\/hostname>/, ""); print ip, $0 }'
}

setup() {
  network_exists || die "the libvirt network '$NETWORK' does not exist - run ./lab up first"
  log "Publishing $FQDN on the lab DNS server ($DNS_IP)"

  local ip
  for ip in $SCAN_IPS; do
    if current_records | grep -qx "$ip $FQDN"; then
      info "$FQDN -> $ip (already present)"
      continue
    fi
    virsh_q net-update "$NETWORK" add dns-host \
      "<host ip='$ip'><hostname>$FQDN</hostname></host>" --live --config >/dev/null \
      || die "could not add the $ip record to $NETWORK"
    info "$FQDN -> $ip added"
  done

  log "Checking the answer from the host"
  if command -v dig >/dev/null; then
    local got
    got=$(dig +short +time=2 +tries=1 "@$DNS_IP" "$FQDN" A | sort | tr '\n' ' ')
    info "$FQDN resolves to: ${got:-nothing}"
    [ -n "$got" ] || die "the DNS server did not answer for $FQDN"
  else
    info "dig is not installed on the host; the lookup is checked from the nodes"
  fi

  info "the nodes use $DNS_IP as their first resolver, with $VAGRANT_NET as a"
  info "fallback for names outside the lab (see 01-base.sh)"
}

status() {
  printf '\n== SCAN DNS records on the "%s" network\n' "$NETWORK"
  if ! network_exists; then
    printf '    the network does not exist (run ./lab up)\n'
    return 1
  fi
  local records
  records=$(current_records || true)
  if [ -z "$records" ]; then
    printf '    no host records defined\n'
    return 1
  fi
  printf '%s\n' "$records" | sed 's/^/    /'

  printf '\n== Resolution\n'
  if command -v dig >/dev/null; then
    printf '    %s -> %s\n' "$FQDN" \
      "$(dig +short +time=2 +tries=1 "@$DNS_IP" "$FQDN" A | tr '\n' ' ')"
  else
    printf '    dig is not installed on the host\n'
  fi
}

teardown() {
  log "Removing the SCAN records from $NETWORK"
  network_exists || { info "the network does not exist"; return 0; }
  local ip
  for ip in $SCAN_IPS; do
    virsh_q net-update "$NETWORK" delete dns-host \
      "<host ip='$ip'><hostname>$FQDN</hostname></host>" --live --config >/dev/null 2>&1 || true
    info "$ip removed (if it was there)"
  done
}

case "${1:-setup}" in
  setup)    setup ;;
  status)   status ;;
  teardown) teardown ;;
  *)
    printf 'Usage: %s setup|status|teardown\n' "$0" >&2
    exit 2
    ;;
esac
