#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Offline tests for install.sh and vpn, run inside a temporary root (VPN_PREFIX).
# Needs root plus wg, wg-quick, qrencode and unbound-checkconf.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VPN_PREFIX=$T/root
VPN=$ROOT/vpn
WG_CONF=$VPN_PREFIX/etc/wireguard/wg0.conf
BLOCKLIST=$VPN_PREFIX/etc/unbound/unbound.conf.d/vpn-blocklist.conf

failures=0
ok() { echo "ok   - $*"; }
not_ok() { echo "FAIL - $*"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else not_ok "$desc"; fi
}
blocked() { grep -qxF "    local-zone: \"$1.\" always_nxdomain" "$BLOCKLIST"; }
allowed() { grep -qxF "    local-zone: \"$1.\" transparent" "$BLOCKLIST"; }
not() { ! "$@"; }

# ---------------------------------------------------------------- fixtures

cat >"$T/hosts.txt" <<'EOF'
# a hosts file
127.0.0.1 localhost
::1 ip6-localhost
0.0.0.0 0.0.0.0
0.0.0.0 ads.example.com
0.0.0.0 tracker.example.net # trailing comment
0.0.0.0 CAPS.Example.ORG
0.0.0.0 allowed.example.com
0.0.0.0 multi1.test multi2.test
EOF
printf '%s\r\n' "example.net" "sub.ads.example.com" "||adblock.example^" "*.wild.example" \
	"bad..example" "-bad.example" "example-foo.net" "10.1.2.3" >"$T/domains.txt"

# ---------------------------------------------------------------- install

(
	# shellcheck source=install.sh
	. "$ROOT/install.sh"
	VPN_ENDPOINT=203.0.113.7
	VPN_PORT=51820
	VPN_WAN_IFACE=eth0
	VPN_IPV6=yes
	VPN_IPV6_NET=fd12:3456:789a
	VPN_MTU=1420
	VPN_DNS=quad9
	VPN_BLOCKLISTS="file://$T/hosts.txt file://$T/domains.txt file://$T/missing.txt"
	write_settings
	write_sysctl
	write_wireguard_conf
	write_unbound_conf
	write_systemd_units
)
cat >"$VPN_PREFIX/etc/unbound/unbound.conf" <<EOF
include: "$VPN_PREFIX/etc/unbound/unbound.conf.d/*.conf"
EOF

check "wg0.conf is private" test "$(stat -c %a "$WG_CONF")" = 600
check "unbound config is valid" unbound-checkconf "$VPN_PREFIX/etc/unbound/unbound.conf"
check "unbound uses DNS-over-TLS to quad9" grep -q 'forward-addr: 9.9.9.9@853#dns.quad9.net' \
	"$VPN_PREFIX/etc/unbound/unbound.conf.d/vpn.conf"
check "unbound listens on IPv6" grep -qx '    interface: fd12:3456:789a::1' \
	"$VPN_PREFIX/etc/unbound/unbound.conf.d/vpn.conf"
check "sysctl keeps router advertisements" grep -qx 'net.ipv6.conf.eth0.accept_ra = 2' \
	"$VPN_PREFIX/etc/sysctl.d/99-vpn.conf"

# ---------------------------------------------------------------- blocklists

check "update succeeds with one list missing" "$VPN" update
check "unbound accepts the blocklist" unbound-checkconf "$VPN_PREFIX/etc/unbound/unbound.conf"
for d in ads.example.com caps.example.org allowed.example.com multi1.test multi2.test \
	example.net adblock.example wild.example example-foo.net use-application-dns.net mask.icloud.com; do
	check "blocks $d" blocked "$d"
done
for d in tracker.example.net sub.ads.example.com localhost ip6-localhost 0.0.0.0 \
	bad..example -bad.example 10.1.2.3; do
	check "does not list $d" not blocked "$d"
done
check "no duplicate zones" test -z "$(grep local-zone "$BLOCKLIST" | sort | uniq -d)"

check "allow a blocked domain" "$VPN" allow allowed.example.com
check "  it is no longer blocked" not blocked allowed.example.com
check "  it is explicitly allowed" allowed allowed.example.com
check "allow a subdomain of a blocked domain" "$VPN" allow sub.ads.example.com
check "  the parent stays blocked" blocked ads.example.com
check "  the subdomain is allowed" allowed sub.ads.example.com
check "unallow" "$VPN" unallow allowed.example.com
check "  it is blocked again" blocked allowed.example.com
check "block a custom domain" "$VPN" block My.Custom.Test
check "  it is blocked" blocked my.custom.test
check "unblock it" "$VPN" unblock my.custom.test
check "  it is not blocked" not blocked my.custom.test
check "reject an invalid domain" not "$VPN" block 'not a domain'
check "unbound accepts the final blocklist" unbound-checkconf "$VPN_PREFIX/etc/unbound/unbound.conf"

# ---------------------------------------------------------------- clients

check "add phone" "$VPN" add phone
check "add laptop" "$VPN" add laptop
check "reject a duplicate client" not "$VPN" add phone
check "reject a bad client name" not "$VPN" add 'bad name'
check "phone got 10.8.0.2" grep -qx 'Address = 10.8.0.2/32, fd12:3456:789a::2/128' "$VPN_PREFIX/etc/vpn/clients/phone.conf"
check "laptop got 10.8.0.3" grep -qx 'Address = 10.8.0.3/32, fd12:3456:789a::3/128' "$VPN_PREFIX/etc/vpn/clients/laptop.conf"
check "client config is private" test "$(stat -c %a "$VPN_PREFIX/etc/vpn/clients/phone.conf")" = 600
check "client uses the VPN's DNS" grep -qx 'DNS = 10.8.0.1, fd12:3456:789a::1' "$VPN_PREFIX/etc/vpn/clients/phone.conf"
check "client sends all traffic through the VPN" grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0' "$VPN_PREFIX/etc/vpn/clients/phone.conf"
check "client endpoint" grep -qx 'Endpoint = 203.0.113.7:51820' "$VPN_PREFIX/etc/vpn/clients/phone.conf"
server_pub=$(awk -F' = ' '/^PrivateKey/ { print $2; exit }' "$WG_CONF" | wg pubkey)
check "client knows the server key" grep -qxF "PublicKey = $server_pub" "$VPN_PREFIX/etc/vpn/clients/phone.conf"
check "wg-quick parses the server config" wg-quick strip "$WG_CONF"
check "server config has 2 peers" test "$(wg-quick strip "$WG_CONF" | grep -c '^\[Peer\]')" = 2

check "remove phone" "$VPN" remove phone
check "  its peer is gone" not grep -q 'client: phone' "$WG_CONF"
check "  its config is gone" test ! -e "$VPN_PREFIX/etc/vpn/clients/phone.conf"
check "reject removing an unknown client" not "$VPN" remove phone
check "add tablet" "$VPN" add tablet
check "  tablet reuses 10.8.0.2" grep -q '^Address = 10.8.0.2/32' "$VPN_PREFIX/etc/vpn/clients/tablet.conf"
check "wg-quick still parses the server config" wg-quick strip "$WG_CONF"
list=$("$VPN" list)
check "list shows tablet and laptop" grep -q 'tablet.*10.8.0.2' <<<"$list"
check "  and not phone" not grep -q phone <<<"$list"
check "status runs" "$VPN" status

# ---------------------------------------------------------------- remote install

# A fake ssh runs the remote command locally, and a fake env records how the
# installer would have been started instead of running it.
mkdir -p "$T/bin" "$T/home"
# shellcheck disable=SC2016 # these are scripts, expanded when they run
printf '%s\n' '#!/bin/sh' 'for cmd; do :; done' 'cd "$FAKE_HOME" && sh -c "$cmd"' >"$T/bin/ssh"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >"$FAKE_HOME/env-args"' >"$T/bin/env"
chmod +x "$T/bin/ssh" "$T/bin/env"
check "install from another computer" /usr/bin/env FAKE_HOME="$T/home" PATH="$T/bin:$PATH" \
	VPN_PORT=443 VPN_LISTS="file:///it's here" "$ROOT/install.sh" root@203.0.113.7
for f in vpn install.sh uninstall.sh; do
	check "  copies $f" test -x "$T/home/private-vpn/$f"
done
check "  runs the installer" grep -qx 'private-vpn/install.sh' "$T/home/env-args"
check "  passes settings" grep -qx 'VPN_PORT=443' "$T/home/env-args"
check "  quotes settings" grep -qxF "VPN_LISTS=file:///it's here" "$T/home/env-args"

echo
if ((failures)); then
	echo "$failures test(s) failed"
	exit 1
fi
echo "all tests passed"
