#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

mkdir -p "$WORKDIR"

# Xóa proxy hiện tại và giữ lại 3proxy
clear_proxy_and_file() {
    echo "" > /usr/local/etc/3proxy/3proxy.cfg
    echo "" > "$WORKDATA"
    echo "" > "$WORKDIR/proxy.txt"

    if [ -f "$WORKDIR/boot_ifconfig_delete.sh" ]; then
        chmod +x "$WORKDIR/boot_ifconfig_delete.sh"
        bash "$WORKDIR/boot_ifconfig_delete.sh"
    fi

    systemctl stop 3proxy || true
    systemctl restart NetworkManager || true

    echo "" > "$WORKDIR/boot_ifconfig.sh"
}

# Sinh chuỗi ngẫu nhiên
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Sinh IPv6 ngẫu nhiên từ prefix
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Sinh cấu hình cho 3proxy
gen_3proxy() {
    cat <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "${WORKDATA}")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush\n"}' "${WORKDATA}")
EOF
}

# Xuất file proxy cho user
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "${WORKDATA}" > "$WORKDIR/proxy.txt"
}

# Tạo dữ liệu ngẫu nhiên
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# Sinh script gán địa chỉ IPv6
gen_ifconfig() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr add " $5 "/64 dev " iface}' "${WORKDATA}" > "${WORKDIR}/boot_ifconfig.sh"
}

# Sinh script xóa địa chỉ IPv6
gen_ifconfig_delete() {
    awk -F "/" -v iface="$IFACE" '{print "ip -6 addr del " $5 "/64 dev " iface}' "${WORKDATA}" > "${WORKDIR}/boot_ifconfig_delete.sh"
}

# --- Bắt đầu xử lý ---
clear_proxy_and_file

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "🔍 Internal IPv4: $IP4"
echo "🔍 IPv6 Prefix: $IP6"
echo "How many proxy do you want to create?"
read -r COUNT

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Số không hợp lệ"
    exit 1
fi

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

# Tạo dữ liệu proxy và script
gen_data > "$WORKDATA"
gen_ifconfig
gen_ifconfig_delete
chmod +x "$WORKDIR/boot_ifconfig.sh" "$WORKDIR/boot_ifconfig_delete.sh"

# Gán IPv6
bash "$WORKDIR/boot_ifconfig.sh"

# Cấu hình 3proxy
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
chmod 644 /usr/local/etc/3proxy/3proxy.cfg

# Khởi động lại 3proxy
ulimit -n 10048
systemctl daemon-reload
systemctl restart 3proxy

# Ghi file cho người dùng
gen_proxy_file_for_user

echo "✅ Xoay proxy thành công!"
echo "- Danh sách proxy: $WORKDIR/proxy.txt"
echo "- Nếu reboot VPS, chạy lại: bash $WORKDIR/boot_ifconfig.sh"
echo "Rotate Done"
