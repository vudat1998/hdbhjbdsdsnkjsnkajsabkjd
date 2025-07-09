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
IPV4_BASE_PORT="$3"     # Cổng bắt đầu cho proxy IPv4
IPV6_BASE_PORT="$4"     # Cổng bắt đầu cho proxy IPv6
IPV4_COUNT="$5"         # Số lượng proxy IPv4
IPV6_COUNT="$6"         # Số lượng proxy IPv6

# --- Thư mục lưu trữ ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%&^_+-'

# --- Tìm interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "✅ Sử dụng interface: $NET_IF"

# --- Mảng hex và hàm sinh đoạn IPv6 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

ip64() {
  echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
}

generate_ipv6() {
  echo "$IPV6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# --- Tạo proxy IPv4 ---
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
for i in $(seq 1 "$IPV6_COUNT"); do
  PORT=$((IPV6_BASE_PORT + i - 1))

  # Tạo user có ít nhất 1 ký tự đặc biệt
  while true; do
    USER_RAW=$(tr -dc A-Za-z010-9 </dev/urandom | head -c6)
    SPECIAL=$(tr -dc '@%&^_+-' </dev/urandom | head -c2)
    USER="${USER_RAW}${SPECIAL}"
    echo "$USER" | grep -q '[@%&^_+-]' && break
  done

  # Tạo pass có ít nhất 1 ký tự đặc biệt
  while true; do
    PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
    echo "$PASS" | grep -q '[@%&^_+-]' && break
  done

  IP6=$(generate_ipv6)

  # Gán IPv6 vào interface nếu chưa có
  if ! ip -6 addr show dev "$NET_IF" | grep -q "${IP6}/64"; then
    ip -6 addr add "${IP6}/64" dev "$NET_IF" || {
      echo "⚠️ Không thể gán IPv6: $IP6, bỏ qua..."
    }
  fi

  echo "$USER/$PASS/-/$PORT/$IP6" >> "$WORKDATA"
done

# --- Tạo cấu hình 3proxy ---
{
  echo "maxconn 10000"
  echo "nscache 65536"
  echo "timeouts 1 5 30 60 180 1800 15 60"
  echo "setgid 65535"
  echo "setuid 65535"
  echo "flush"

  # users
  echo -n "users "
  awk -F "/" '{
    gsub(/[:\\]/, "\\\\&", $2);  # escape `:` và `\`
    printf "%s:CL:%s ", $1, $2
  }' "$WORKDATA"
  echo ""
  
  echo "auth strong"

  # rules for IPv4 proxies
  awk -F "/" '$3 != "-" {
    u=$1; p=$2; ip4=$3; port=$4;
    print "allow " u
    print "proxy -n -a -p" port " -i0.0.0.0 -e" ip4
  }' "$WORKDATA"

  # rules for IPv6 proxies
  awk -F "/" '$5 != "-" {
    u=$1; p=$2; port=$4; ip6=$5;
    print "allow " u
    print "proxy -n -a -p" port " -i:: -e" ip6
  }' "$WORKDATA"
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

[Install]
WantedBy=multi-user.target
EOF

# --- Mở firewall và iptables ---
if systemctl is-active --quiet firewalld; then
  for port in $(awk -F "/" '{print $4}' "$WORKDATA" | sort -u); do
    firewall-cmd --permanent --add-port=${port}/tcp || true
  done
  firewall-cmd --reload || true
fi

for port in $(awk -F "/" '{print $4}' "$WORKDATA" | sort -u); do
  iptables -I INPUT -p tcp --dport ${port} -j ACCEPT || true
  ip6tables -I INPUT -p tcp --dport ${port} -j ACCEPT || true
done

# --- Khởi động lại 3proxy ---
echo "🔁 Restart 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

# --- Kiểm tra trạng thái 3proxy ---
if systemctl is-active --quiet 3proxy; then
  echo "✅ Dịch vụ 3proxy đang chạy."
else
  echo "❌ Dịch vụ 3proxy không chạy. Kiểm tra log bằng: journalctl -u 3proxy"
  exit 1
fi

# --- Xuất proxy.txt ---
while IFS="/" read -r USER PASS IP4 PORT IP6; do
  if [ "$IP4" != "-" ]; then
    echo "${USER}:${PASS}:${IP4}:${PORT}" >> "$PROXY_TXT"
  fi
  if [ "$IP6" != "-" ]; then
    echo "${USER}:${PASS}:${IP6}:${PORT}" >> "$PROXY_TXT"
  fi
done < "$WORKDATA"

echo "✅ Đã tạo $IPV4_COUNT proxy IPv4 (từ cổng $IPV4_BASE_PORT) và $IPV6_COUNT proxy IPv6 (từ cổng $IPV6_BASE_PORT)"
echo "📄 File proxy: $PROXY_TXT"
cat "$PROXY_TXT"
echo "Install Done"
