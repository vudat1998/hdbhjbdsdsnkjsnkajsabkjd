#!/bin/bash

echo "[*] Stopping 3proxy service if running..."
systemctl stop 3proxy 2>/dev/null
pkill 3proxy 2>/dev/null

echo "[*] Removing 3proxy systemd service..."
rm -f /etc/systemd/system/3proxy.service
systemctl daemon-reload

echo "[*] Deleting 3proxy installation files..."
rm -rf /usr/local/etc/3proxy

echo "[*] Removing iptables rules if available..."
if [ -f /home/proxy-installer/boot_iptables_delete.sh ]; then
    bash /home/proxy-installer/boot_iptables_delete.sh
fi

echo "[*] Removing assigned IPv6 addresses if available..."
if [ -f /home/proxy-installer/boot_ifconfig_delete.sh ]; then
    bash /home/proxy-installer/boot_ifconfig_delete.sh
fi

echo "[*] Deleting proxy-installer folder..."
rm -rf /home/proxy-installer

echo "Delete Done"
