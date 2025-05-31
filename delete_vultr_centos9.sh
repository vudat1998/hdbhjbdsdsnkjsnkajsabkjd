#!/bin/bash

WORKDIR="/home/proxy-installer"
CONFIG_FILE="/usr/local/etc/3proxy/3proxy.cfg"

echo "==> Đang xoá proxy cũ..."

# Kill 3proxy nếu đang chạy
pkill -f 3proxy || true
systemctl stop 3proxy || true
systemctl disable 3proxy || true

# Gỡ IPv6 khỏi interface nếu có
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -f "${WORKDIR}/boot_ifconfig_delete.sh" ]; then
    chmod +x "${WORKDIR}/boot_ifconfig_delete.sh"
    bash "${WORKDIR}/boot_ifconfig_delete.sh"
fi

# Xóa firewall rule nếu cần (mở rộng nếu cần sau này)
firewall-cmd --reload || true

# Xoá thư mục proxy và config
rm -rf "$WORKDIR"
rm -rf /usr/local/etc/3proxy
rm -f /etc/systemd/system/3proxy.service
systemctl daemon-reexec
systemctl daemon-reload

echo "Delete Done"
