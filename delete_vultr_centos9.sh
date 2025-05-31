#!/bin/bash

# Đường dẫn thư mục cài đặt
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
CONFIG="/usr/local/etc/3proxy/3proxy.cfg"
SERVICE="/etc/systemd/system/3proxy.service"

# Lấy số port đã tạo để xóa firewall đúng
if [[ -f "$WORKDATA" ]]; then
    COUNT=$(wc -l < "$WORKDATA")
else
    echo "Không tìm thấy file $WORKDATA, không rõ số lượng port đã tạo. Đặt COUNT=0"
    COUNT=0
fi

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

echo "🧹 Bắt đầu gỡ bỏ proxy IPv6..."

# 1. Gỡ IPv6 khỏi interface
if [[ -x "${WORKDIR}/boot_ifconfig_delete.sh" ]]; then
    echo "➖ Xoá IPv6 khỏi interface..."
    bash "${WORKDIR}/boot_ifconfig_delete.sh"
else
    echo "⚠️ Không tìm thấy boot_ifconfig_delete.sh"
fi

# 2. Gỡ port trên firewalld nếu có
if command -v firewall-cmd &> /dev/null && firewall-cmd --state &> /dev/null && [ "$COUNT" -gt 0 ]; then
    echo "➖ Xoá rule mở port ${FIRST_PORT}-${LAST_PORT} trên firewalld..."
    firewall-cmd --permanent --remove-port=${FIRST_PORT}-${LAST_PORT}/tcp
    firewall-cmd --reload
else
    echo "⚠️ Firewalld không chạy hoặc không có port để xóa"
fi

# 3. Dừng 3proxy và xóa config
if systemctl is-active --quiet 3proxy; then
    echo "🛑 Dừng dịch vụ 3proxy..."
    systemctl stop 3proxy
fi

if [[ -f "$CONFIG" ]]; then
    echo "🗑️ Xoá file cấu hình 3proxy..."
    > "$CONFIG"
fi

if [[ -f "$SERVICE" ]]; then
    echo "🗑️ Xoá file service 3proxy..."
    rm -f "$SERVICE"
    systemctl daemon-reload
fi

# 4. Xoá dữ liệu và script
echo "🧼 Xoá dữ liệu proxy và script..."
rm -f "${WORKDIR}/data.txt" \
      "${WORKDIR}/proxy.txt" \
      "${WORKDIR}/boot_ifconfig.sh" \
      "${WORKDIR}/boot_ifconfig_delete.sh"

echo "✅ Đã xoá toàn bộ cấu hình proxy IPv6 trên máy chủ."
