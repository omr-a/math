#!/usr/bin/env bash
# Remove the private VPN installed by install.sh, including all clients.
# The packages (wireguard-tools, unbound, ...) are left installed.
#
# Usage: sudo ./uninstall.sh [-y]
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "error: run as root: sudo ./uninstall.sh" >&2; exit 1; }

if [[ ${1:-} != -y ]]; then
	read -r -p "This deletes the VPN and every client config. Continue? [y/N] " answer </dev/tty
	[[ $answer == [yY]* ]] || exit 1
fi

iface=wg0
if [[ -r /etc/vpn/vpn.conf ]]; then
	# shellcheck source=/dev/null
	. /etc/vpn/vpn.conf
	iface=$VPN_IFACE
fi

# Stopping the interface also removes the firewall rules (PostDown).
systemctl disable -q --now vpn-blocklist.timer "wg-quick@$iface" 2>/dev/null || true
rm -f /etc/systemd/system/vpn-blocklist.service /etc/systemd/system/vpn-blocklist.timer
systemctl daemon-reload

rm -f /etc/unbound/unbound.conf.d/vpn.conf /etc/unbound/unbound.conf.d/vpn-blocklist.conf
systemctl disable -q --now unbound 2>/dev/null || true

rm -f "/etc/wireguard/$iface.conf" /etc/sysctl.d/99-vpn.conf /usr/local/bin/vpn
rm -rf /etc/vpn /var/lib/vpn

echo "==> VPN removed. To remove the packages too:"
echo "    sudo apt-get purge wireguard-tools unbound qrencode"
