#!/usr/bin/env bash
# Install a private WireGuard VPN with an ad-blocking DNS resolver.
#
# Usage, on the server:              sudo ./install.sh
#        or from your own computer:  ./install.sh root@SERVER_IP
#
# The second form copies these scripts to the server over SSH and installs
# there, so the QR code shows up on your own screen.
#
# Optional settings, passed as environment variables:
#   VPN_ENDPOINT  public IP or domain name of this server (auto-detected)
#   VPN_PORT      UDP port to listen on (default 51820)
#   VPN_DNS       recursive | quad9 | cloudflare (default recursive)
#   VPN_LISTS     light | normal | pro, or blocklist URLs (default normal)
#   VPN_IPV6      yes | no (auto-detected)
#   VPN_MTU       tunnel MTU for clients (default 1420; 1280 for bad networks)
#   VPN_CLIENT    name of the first client (default phone)
#
# Example: sudo VPN_PORT=443 VPN_LISTS=pro ./install.sh
set -euo pipefail

# VPN_PREFIX relocates every path below; it exists only for the tests.
PREFIX=${VPN_PREFIX:-}
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HAGEZI=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard

VPN_IFACE=wg0
VPN_IPV4_NET=10.8.0

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Single-quote a value for the remote shell.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

remote_install() {
	local target=$1 vars="" var payload
	for var in VPN_ENDPOINT VPN_PORT VPN_DNS VPN_LISTS VPN_IPV6 VPN_MTU VPN_CLIENT; do
		if [[ -n ${!var:-} ]]; then vars+=" $var=$(quote "${!var}")"; fi
	done
	# Sent inside the command itself, so one SSH login (and password) is enough.
	payload=$(cd "$SRC_DIR" && COPYFILE_DISABLE=1 tar -czf - vpn install.sh uninstall.sh | base64 | tr -d '\n')
	info "connecting to $target"
	exec ssh -t "$target" "set -e
mkdir -p private-vpn
echo $payload | base64 -d | tar --warning=no-unknown-keyword -xzf - -C private-vpn
if [ \"\$(id -u)\" -eq 0 ]; then sudo=; else sudo=sudo; fi
\$sudo env$vars private-vpn/install.sh"
}

check_system() {
	[[ $EUID -eq 0 ]] || die "run as root: sudo ./install.sh"
	if [[ ! -f /etc/debian_version ]] || ! command -v apt-get >/dev/null; then
		die "only Debian and Ubuntu are supported"
	fi
	[[ ! -e /etc/vpn/vpn.conf ]] ||
		die "the VPN is already installed; manage it with 'vpn help' or run ./uninstall.sh first"
}

install_packages() {
	info "installing packages"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -y -q --no-install-recommends \
		wireguard-tools unbound dns-root-data qrencode iptables iproute2 curl ca-certificates
}

check_kernel() {
	# WireGuard runs inside the kernel (Linux 5.6+), which is what makes it fast.
	if ! ip link add vpn-probe0 type wireguard 2>/dev/null; then
		modprobe wireguard 2>/dev/null || true
		ip link add vpn-probe0 type wireguard 2>/dev/null ||
			die "this kernel has no WireGuard support; use a KVM server with Linux 5.6+ (OpenVZ/LXC won't work)"
	fi
	ip link del vpn-probe0
}

detect_settings() {
	info "detecting network settings"
	VPN_WAN_IFACE=$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
	[[ -n $VPN_WAN_IFACE ]] || die "no default IPv4 route found"

	if [[ -z ${VPN_ENDPOINT:-} ]]; then
		local url ip
		for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
			ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || continue
			[[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { VPN_ENDPOINT=$ip; break; }
		done
		[[ -n ${VPN_ENDPOINT:-} ]] || die "could not detect the public IP; set VPN_ENDPOINT=..."
	fi

	if [[ -z ${VPN_IPV6:-} ]]; then
		VPN_IPV6=no
		if [[ -n $(ip -6 route show default 2>/dev/null) && -n $(ip -6 addr show scope global 2>/dev/null) ]]; then
			VPN_IPV6=yes
		fi
	fi
	# A random private (ULA) IPv6 prefix, e.g. fd3a:91c2:7f0e (RFC 4193).
	local hex
	hex=$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')
	VPN_IPV6_NET=fd${hex:0:2}:${hex:2:4}:${hex:6:4}

	VPN_PORT=${VPN_PORT:-51820}
	VPN_MTU=${VPN_MTU:-1420}
	VPN_DNS=${VPN_DNS:-recursive}
	case $VPN_DNS in
	recursive | quad9 | cloudflare) ;;
	*) die "VPN_DNS must be recursive, quad9 or cloudflare" ;;
	esac
	case ${VPN_LISTS:-normal} in
	light) VPN_BLOCKLISTS=$HAGEZI/light-onlydomains.txt ;;
	normal) VPN_BLOCKLISTS=$HAGEZI/multi-onlydomains.txt ;;
	pro) VPN_BLOCKLISTS=$HAGEZI/pro-onlydomains.txt ;;
	*) VPN_BLOCKLISTS=$VPN_LISTS ;;
	esac
}

write_settings() {
	mkdir -p "$PREFIX/etc/vpn/clients"
	chmod 700 "$PREFIX/etc/vpn/clients"
	touch "$PREFIX/etc/vpn/allowlist.txt" "$PREFIX/etc/vpn/blocklist.txt"
	cat >"$PREFIX/etc/vpn/vpn.conf" <<EOF
# Settings of the private VPN, read by the 'vpn' command.
VPN_ENDPOINT="$VPN_ENDPOINT"
VPN_PORT="$VPN_PORT"
VPN_IFACE="$VPN_IFACE"
VPN_WAN_IFACE="$VPN_WAN_IFACE"
VPN_IPV4_NET="$VPN_IPV4_NET"
VPN_IPV6="$VPN_IPV6"
VPN_IPV6_NET="$VPN_IPV6_NET"
VPN_MTU="$VPN_MTU"
VPN_DNS="$VPN_DNS"
# Space-separated URLs of hosts files or domain lists; apply with 'vpn update'.
VPN_BLOCKLISTS="$VPN_BLOCKLISTS"
EOF
}

write_sysctl() {
	mkdir -p "$PREFIX/etc/sysctl.d"
	{
		echo "# Written by the VPN installer."
		echo "net.ipv4.ip_forward = 1"
		if [[ $VPN_IPV6 == yes ]]; then
			echo "net.ipv6.conf.all.forwarding = 1"
			# Forwarding turns off router advertisements; keep the server's own IPv6.
			echo "net.ipv6.conf.$VPN_WAN_IFACE.accept_ra = 2"
		fi
	} >"$PREFIX/etc/sysctl.d/99-vpn.conf"
}

write_wireguard_conf() {
	local addr="$VPN_IPV4_NET.1/24"
	[[ $VPN_IPV6 == yes ]] && addr+=", $VPN_IPV6_NET::1/64"
	mkdir -p "$PREFIX/etc/wireguard"
	(
		umask 077
		cat >"$PREFIX/etc/wireguard/$VPN_IFACE.conf" <<EOF
# Server side of the private VPN. Manage clients with 'vpn add/remove NAME';
# the blocks between '### client' and '### end' lines belong to the vpn command.
[Interface]
Address = $addr
ListenPort = $VPN_PORT
PrivateKey = $(wg genkey)
PostUp = /usr/local/bin/vpn firewall up
PostDown = /usr/local/bin/vpn firewall down
EOF
	)
}

write_unbound_conf() {
	local conf=$PREFIX/etc/unbound/unbound.conf.d/vpn.conf
	mkdir -p "$(dirname "$conf")"
	{
		cat <<EOF
# Private, ad-blocking DNS resolver for the VPN clients. Written by install.sh.
server:
    interface: $VPN_IPV4_NET.1
EOF
		[[ $VPN_IPV6 == yes ]] && echo "    interface: $VPN_IPV6_NET::1"
		cat <<EOF
    # Start before the VPN interface exists.
    ip-freebind: yes
    access-control: 0.0.0.0/0 refuse
    access-control: ::/0 refuse
    access-control: $VPN_IPV4_NET.0/24 allow
EOF
		[[ $VPN_IPV6 == yes ]] && echo "    access-control: $VPN_IPV6_NET::/64 allow"
		cat <<EOF
    do-ip6: $VPN_IPV6

    # Small footprint.
    module-config: "validator iterator"
    num-threads: 1
    msg-cache-size: 8m
    rrset-cache-size: 16m

    # Speed: refresh popular names before they expire and answer from the
    # cache while refreshing.
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    edns-buffer-size: 1232

    # Privacy: no logs, send as little as possible upstream.
    verbosity: 0
    log-queries: no
    log-replies: no
    log-local-actions: no
    log-servfail: no
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    minimal-responses: yes
    aggressive-nsec: yes

    # Security: DNSSEC hardening and DNS-rebinding protection.
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    unwanted-reply-threshold: 10000
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
    private-address: ::ffff:0:0/96
EOF
		if [[ $VPN_DNS != recursive ]]; then
			local name ips
			if [[ $VPN_DNS == quad9 ]]; then
				name=dns.quad9.net ips="9.9.9.9 149.112.112.112"
				[[ $VPN_IPV6 == yes ]] && ips+=" 2620:fe::fe 2620:fe::9"
			else
				name=cloudflare-dns.com ips="1.1.1.1 1.0.0.1"
				[[ $VPN_IPV6 == yes ]] && ips+=" 2606:4700:4700::1111 2606:4700:4700::1001"
			fi
			cat <<EOF
    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

# Encrypted (DNS-over-TLS) upstream instead of resolving from the root servers.
forward-zone:
    name: "."
    forward-tls-upstream: yes
EOF
			local ip
			for ip in $ips; do echo "    forward-addr: $ip@853#$name"; done
		fi
	} >"$conf"
}

write_systemd_units() {
	local dir=$PREFIX/etc/systemd/system
	mkdir -p "$dir"
	cat >"$dir/vpn-blocklist.service" <<'EOF'
[Unit]
Description=Update the VPN ad-blocking lists
Wants=network-online.target
After=network-online.target unbound.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn update
Nice=10
EOF
	cat >"$dir/vpn-blocklist.timer" <<'EOF'
[Unit]
Description=Update the VPN ad-blocking lists daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

main() {
	check_system
	install_packages
	check_kernel
	detect_settings

	info "configuring (endpoint $VPN_ENDPOINT:$VPN_PORT, IPv6 $VPN_IPV6, DNS $VPN_DNS)"
	install -m 755 "$SRC_DIR/vpn" /usr/local/bin/vpn
	write_settings
	write_sysctl
	sysctl -q -p /etc/sysctl.d/99-vpn.conf
	write_wireguard_conf
	write_unbound_conf
	write_systemd_units

	info "starting services"
	systemctl enable -q unbound
	systemctl restart unbound || die "unbound did not start; see: journalctl -u unbound"
	systemctl enable -q --now "wg-quick@$VPN_IFACE"
	systemctl daemon-reload
	systemctl enable -q --now vpn-blocklist.timer

	info "downloading blocklists"
	vpn update

	vpn add "${VPN_CLIENT:-phone}"

	cat <<EOF

Done! Your private VPN is running.

  1. If your provider has a cloud firewall, allow UDP port $VPN_PORT there.
  2. Install the WireGuard app and scan the QR code above.
  3. Add more devices on the server with:  sudo vpn add laptop

See all commands with:  vpn help
EOF
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	case ${1:-} in
	-*)
		echo "usage: sudo ./install.sh   (on the server)"
		echo "       ./install.sh root@SERVER_IP   (from your own computer)"
		;;
	?*) remote_install "$1" ;;
	*)
		[[ $(uname -s) == Linux ]] ||
			die "the VPN runs on a Linux server, not on this computer. Get a server (see README.md), then run from here:  ./install.sh root@SERVER_IP"
		main
		;;
	esac
fi
