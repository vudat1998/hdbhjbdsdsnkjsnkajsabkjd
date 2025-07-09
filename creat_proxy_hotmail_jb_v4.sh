#!/bin/bash
set -e

# --- Kiểm tra tham số đầu vào ---
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ]; then
    echo "❌ Cú pháp: bash $0 <IPv4> <IPv6_PREFIX> <IPV4_BASE_PORT> <IPV6_BASE_PORT> <IPV4_COUNT> <IPV6_COUNT>"
    echo "   VD: bash $0 45.76.215.61 2001:19f0:7002:0c3a 30000 40000 100 500"
    exit 1
fi

IPV4="$1"
IPV6_PREFIX="$2"
IPV4_BASE_PORT="$3"
IPV6_BASE_PORT="$4"
IPV4_COUNT="$5"
IPV6_COUNT="$6"

# Kiểm tra đầu vào là số nguyên
if ! [[ "$IPV4_BASE_PORT" =~ ^[0-9]+$ ]] || ! [[ "$IPV6_BASE_PORT" =~ ^[0-9]+$ ]] || ! [[ "$IPV4_COUNT" =~ ^[0-9]+$ ]] || ! [[ "$IPV6_COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ Các tham số BASE_PORT, IPV4_COUNT, IPV6_COUNT phải là số nguyên!"
    exit 1
fi

# --- Thư mục làm việc ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Tìm interface mạng ---
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$IFACE" ]; then
    echo "❌ Lỗi: Không phát hiện được interface mạng IPv4 mặc định."
    exit 1
fi
echo "✅ Interface mạng: $IFACE"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%&^_+-'

# --- Hàm tạo IPv6 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# --- Tạo proxy IPv4 ---
echo "✅ Tạo $IPV4_COUNT proxy IPv4..."
IPV4_LAST_PORT=$((IPV4_BASE_PORT + IPV4_COUNT - 1))
seq "$IPV4_BASE_PORT" "$IPV4_LAST_PORT" | while read -r port; do
    # Tạo user có ít nhất 1 ký tự đặc biệt
    while true; do
        USER_RAW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c10)
        SPECIAL=$(tr -dc '@%&^_+-' </dev/urandom | head -c2)
        USER="${USER_RAW}${SPECIAL}"
        echo "$USER" | grep -q '[@%&^_+-]' && break
    done

    # Tạo pass có ít nhất 1 ký tự đặc biệt
    while true; do
        PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
        echo "$PASS" | grep -q '[@%&^_+-]' && break
    done

    echo "$USER/$PASS/$IPV4/$port/-" >> "$WORKDATA"
done

# --- Tạo proxy IPv6 ---
echo "✅ Tạo $IPV6_COUNT proxy IPv6..."
IPV6_LAST_PORT=$((IPV6_BASE_PORT + IPV6_COUNT - 1))
seq "$IPV6_BASE_PORT" "$IPV6_LAST_PORT" | while read -r port; do
    # Tạo user có ít nhất 1 ký tự đặc biệt
    while true; do
        USER_RAW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c10)
        SPECIAL=$(tr -dc '@%&^_+-' </dev/urandom | head -c2)
        USER="${USER_RAW}${SPECIAL}"
        echo "$USER" | grep -q '[@%&^_+-]' && break
    done

    # Tạo pass có ít nhất 1 ký tự đặc biệt
    while true; do
        PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
        echo "$PASS" | grep -q '[@%&^_+-]' && break
    done

    echo "$USER/$PASS/$IPV4/$port/$(gen64 "$IPV6_PREFIX")" >> "$WORKDATA"
done

# --- Tạo script thêm IPv6 ---
echo "✅ Tạo script thêm IPv6..."
cat >"${WORKDIR}/boot_ifconfig.sh" <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ipv6; do
    if [ "\$ipv6" != "-" ]; then
        ip -6 addr add \$ipv6/64 dev $IFACE && echo "success" || echo "⚠️ Không thể gán IPv6: \$ipv6"
    fi
done < "$WORKDATA"
EOF

chmod +x "${WORKDIR}/boot_ifconfig.sh"

# --- Gán địa chỉ IPv6 ---
echo "✅ Gán địa chỉ IPv6..."
bash "${WORKDIR}/boot_ifconfig.sh"

# --- Tạo file cấu hình 3proxy ---
echo "✅ Tạo file cấu hình 3proxy..."
{
    echo "daemon"
    echo "maxconn 1000"
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"
    echo "setuid 65535"
    echo "flush"
    echo -n "users "
    awk -F "/" '{gsub(/[:\\]/, "\\\\&", $2); printf "%s:CL:%s ", $1, $2}' "$WORKDATA"
    echo ""
    echo "auth strong"
    echo "allow *"
    awk -F "/" '$3 != "-" && $5 == "-" {print "proxy -n -a -p"$4" -i"$3" -e"$3}' "$WORKDATA"
    awk -F "/" '$5 != "-" {print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' "$WORKDATA"
} > "$CONFIG_PATH"
chmod 644 "$CONFIG_PATH"

# --- Mở firewall ---
echo "✅ Mở firewall cho các cổng proxy..."
if ! firewall-cmd --permanent --add-port="${IPV4_BASE_PORT}-${IPV4_LAST_PORT}/tcp" || ! firewall-cmd --permanent --add-port="${IPV6_BASE_PORT}-${IPV6_LAST_PORT}/tcp" || ! firewall-cmd --reload; then
    echo "⚠️ Cảnh báo: Không thể mở firewall hoặc reload. Kiểm tra trạng thái firewalld."
fi

# --- Mở iptables ---
echo "✅ Mở iptables cho các cổng proxy..."
for port in $(awk -F "/" '{print $4}' "$WORKDATA" | sort -u); do
    iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT || echo "⚠️ Không thể mở iptables cho cổng $port"
    ip6tables -I INPUT -p tcp --dport "${port}" -j ACCEPT || echo "⚠️ Không thể mở ip6tables cho cổng $port"
done

# --- Khởi động 3proxy ---
echo "✅ Kích hoạt và khởi động dịch vụ 3proxy..."
systemctl daemon-reload
systemctl restart 3proxy || {
    echo "❌ Lỗi: Không thể khởi động 3proxy. Kiểm tra log bằng: journalctl -u 3proxy"
    exit 1
}

# --- Kiểm tra trạng thái 3proxy ---
if systemctl is-active --quiet 3proxy; then
    echo "✅ Dịch vụ 3proxy đang chạy."
else
    echo "❌ Dịch vụ 3proxy không chạy. Kiểm tra log bằng: journalctl -u 3proxy"
    exit 1
fi

# --- Xuất file proxy.txt ---
echo "✅ Xuất file proxy.txt..."
awk -F "/" '{print $3":"$4":"$1":"$2}' "$WORKDATA" > "$PROXY_TXT"

echo "✅ Hoàn tất tạo proxy!"
echo "- Đã tạo $IPV4_COUNT proxy IPv4 (cổng $IPV4_BASE_PORT-$IPV4_LAST_PORT)"
echo "- Đã tạo $IPV6_COUNT proxy IPv6 (cổng $IPV6_BASE_PORT-$IPV6_LAST_PORT)"
echo "- Danh sách proxy: $PROXY_TXT"
echo "- Sau khi reboot, chạy lại IPv6: bash ${WORKDIR}/boot_ifconfig.sh"
echo "Done"
