#!/bin/bash
set -e

# --- Kiểm tra 3proxy đã cài đặt chưa ---
if ! [ -f /usr/local/etc/3proxy/bin/3proxy ]; then
  echo "❌ 3proxy không được cài đặt ở /usr/local/etc/3proxy/bin/3proxy."
  echo "Chạy script cài đặt 3proxy trước khi tiếp tục."
  exit 1
fi

# --- Tăng ulimits nếu cần ---
CURRENT_ULIMIT=$(ulimit -n)
if [ "$CURRENT_ULIMIT" -lt 20000 ]; then
  echo "⚠️ ulimits quá thấp ($CURRENT_ULIMIT). Tăng lên 524288..."
  echo -e "* soft nofile 524288\n* hard nofile 524288" | sudo tee -a /etc/security/limits.conf
  sudo sed -i '/DefaultLimitNOFILE=/d' /etc/systemd/system.conf
  sudo sed -i '/DefaultLimitNOFILE=/d' /etc/systemd/user.conf
  echo "DefaultLimitNOFILE=524288:524288" | sudo tee -a /etc/systemd/system.conf
  echo "DefaultLimitNOFILE=524288:524288" | sudo tee -a /etc/systemd/user.conf
  sudo systemctl daemon-reexec
  ulimit -n 524288
  NEW_ULIMIT=$(ulimit -n)
  if [ "$NEW_ULIMIT" -lt 20000 ]; then
    echo "❌ Không thể đặt ulimits thành 524288 (hiện tại: $NEW_ULIMIT)."
    echo "Hãy đăng xuất và đăng nhập lại, hoặc chạy 'sudo reboot' và thử lại."
    echo "Sau khi reboot, chạy lại script: bash $0 $IPV4 $IPV6_PREFIX $IPV4_BASE_PORT $IPV6_BASE_PORT $IPV4_COUNT $IPV6_COUNT"
    exit 1
  fi
fi

# --- CẤU HÌNH ĐẦU VÀO ---
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

# --- Thư mục lưu trữ ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Tìm interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "✅ Sử dụng interface: $NET_IF"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%&^_+-'

# --- Mảng hex và hàm sinh đoạn IPv6 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

ip64() {
  echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
}

generate_ipv6() {
  echo "$IPV6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# --- Tạo proxy IPv4 ---
echo "✅ Tạo $IPV4_COUNT proxy IPv4..."
IPV4_LAST_PORT=$((IPV4_BASE_PORT + IPV4_COUNT - 1))
for i in $(seq 1 "$IPV4_COUNT"); do
  PORT=$((IPV4_BASE_PORT + i - 1))
  # Tạo user có ít nhất 1 ký tự đặc biệt
  while true; do
    USER_RAW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c6)
    SPECIAL=$(tr -dc '@%&^_+-' </dev/urandom | head -c2)
    USER="${USER_RAW}${SPECIAL}"
    echo "$USER" | grep -q '[@%&^_+-]' && break
  done
  # Tạo pass có ít nhất 1 ký tự đặc biệt
  while true; do
    PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
    echo "$PASS" | grep -q '[@%&^_+-]' && break
  done
  echo "$USER/$PASS/$IPV4/$PORT/-" >> "$WORKDATA"
done

# --- Tạo proxy IPv6 ---
echo "✅ Tạo $IPV6_COUNT proxy IPv6..."
IPV6_LAST_PORT=$((IPV6_BASE_PORT + IPV6_COUNT - 1))
for i in $(seq 1 "$IPV6_COUNT"); do
  PORT=$((IPV6_BASE_PORT + i - 1))
  # Tạo user có ít nhất 1 ký tự đặc biệt
  while true; do
    USER_RAW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c6)
    SPECIAL=$(tr -dc '@%&^_+-' </dev/urandom | head -c2)
    USER="${USER_RAW}${SPECIAL}"
    echo "$USER" | grep -q '[@%&^_+-]' && break
  done
  # Tạo pass có ít nhất 1 ký tự đặc biệt
  while true; do
    PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
    echo "$PASS" | grep -q '[@%&^_+-]' && break
  done
  IP6_A=$(generate_ipv6)
  IP6_B=$(generate_ipv6)
  echo "$USER/$PASS/$IPV4/$PORT/$IP6_A/$IP6_B" >> "$WORKDATA"
done

# --- Tạo script thêm IPv6 ---
echo "✅ Tạo script thêm IPv6..."
cat >"${WORKDIR}/boot_ifconfig.sh" <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ipv6_a ipv6_b; do
  for ip6 in "$ipv6_a" "$ipv6_b"; do
    [ "$ip6" != "-" ] && ip -6 addr add $ip6/64 dev $NET_IF \
      && echo "✅ Gán IPv6: $ip6" \
      || echo "⚠️ Không thể gán IPv6: $ip6"
  done
done < "$WORKDATA"
EOF

chmod +x "${WORKDIR}/boot_ifconfig.sh"

# --- Gán địa chỉ IPv6 ---
echo "✅ Gán địa chỉ IPv6..."
bash "${WORKDIR}/boot_ifconfig.sh"

# --- Tạo cấu hình 3proxy ---
{
  echo "maxconn 10000"
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
  awk -F "/" '{print "proxy -n -a -p" $4 " -i0.0.0.0 -i:: -e" $3 " -e" $5}' "$WORKDATA"
  awk -F "/" '{print "proxy -6 -n -a -p" $4 " -i0.0.0.0 -e" $6}' "$WORKDATA"
} > "$CONFIG_PATH"
chmod 644 "$CONFIG_PATH"

# --- Sửa file dịch vụ systemd ---
cat << EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg
ExecStart=/usr/local/etc/3proxy/bin/3proxy \$CONFIGFILE
Restart=always
RestartSec=1
KillMode=process
KillSignal=SIGKILL

[Install]
WantedBy=multi-user.target
EOF

# --- Mở firewall và iptables ---
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${IPV4_BASE_PORT}-${IPV4_LAST_PORT}/tcp" || echo "⚠️ Không thể mở firewall cho IPv4 ports"
  firewall-cmd --permanent --add-port="${IPV6_BASE_PORT}-${IPV6_LAST_PORT}/tcp" || echo "⚠️ Không thể mở firewall cho IPv6 ports"
  firewall-cmd --reload && echo "success" || echo "⚠️ Không thể reload firewall"
fi

for port in $(awk -F "/" '{print $4}' "$WORKDATA" | sort -u); do
  iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT || echo "⚠️ Không thể mở iptables cho cổng $port"
  ip6tables -I INPUT -p tcp --dport "${port}" -j ACCEPT || echo "⚠️ Không thể mở ip6tables cho cổng $port"
done

# --- Khởi động lại 3proxy ---
echo "🔁 Restart 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
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

# --- Xuất proxy.txt (chỉ với IPv4) ---
while IFS="/" read -r USER PASS IP4 PORT _ _; do
  # hoặc để rõ IP6_A và IP6_B nếu cần:
  # read -r USER PASS IP4 PORT IP6_A IP6_B
  UE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
  PE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")
  echo "${UE}:${PE}:${IP4}:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Đã tạo $IPV4_COUNT proxy IPv4 (cổng $IPV4_BASE_PORT-$IPV4_LAST_PORT)"
echo "✅ Đã tạo $IPV6_COUNT proxy IPv6 (cổng $IPV6_BASE_PORT-$IPV6_LAST_PORT)"
echo "📄 File proxy: $PROXY_TXT"
cat "$PROXY_TXT"
echo "Install Done"
