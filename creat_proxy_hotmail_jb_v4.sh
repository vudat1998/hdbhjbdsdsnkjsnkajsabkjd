#!/bin/bash
set -e

# --- Kiểm tra 3proxy đã cài đặt chưa ---
if ! [ -f /usr/local/etc/3proxy/bin/3proxy ]; then
  echo "❌ 3proxy không được cài đặt ở /usr/local/etc/3proxy/bin/3proxy."
  echo "Chạy script cài đặt 3proxy trước khi tiếp tục."
  exit 1
fi

# --- CẤU HÌNH ĐẦU VÀO ---
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "❌ Cú pháp: bash $0 <IPv4> <IPv6_PREFIX> [BASE_PORT] [COUNT]"
  echo "   VD: bash $0 45.76.215.61 2001:19f0:7002:0c3a 30000 10"
  exit 1
fi

IPV4="$1"
IPV6_PREFIX="$2"
BASE_PORT="${3:-30000}"     # Mặc định 30000 nếu không truyền
COUNT="${4:-10}"            # Mặc định 10 proxy

# --- Thư mục lưu trữ ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
LOG_PATH="/usr/local/etc/3proxy/logs/3proxy.log"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%&^_+-'

# --- Tìm interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "✅ Sử dụng interface: $NET_IF"

# --- Kiểm tra IPv6 có hoạt động không ---
if ! ping6 -c 1 google.com &>/dev/null; then
  echo "⚠️ IPv6 không hoạt động. Kiểm tra cấu hình mạng hoặc liên hệ nhà cung cấp (Vultr)."
  exit 1
fi

# --- Mảng hex và hàm sinh đoạn IPv6 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

ip64() {
  echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
}

generate_ipv6() {
  echo "$IPV6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# --- Tạo proxy ---
for i in $(seq 1 "$COUNT"); do
  PORT=$((BASE_PORT + i - 1))

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

  IP6=$(generate_ipv6)

  # Gán IPv6 vào interface nếu chưa có
  if ! ip -6 addr show dev "$NET_IF" | grep -q "${IP6}/64"; then
    ip -6 addr add "${IP6}/64" dev "$NET_IF" || {
      echo "⚠️ Không thể gán IPv6: $IP6"
      continue
    }
  fi

  echo "$USER/$PASS/$IPV4/$PORT/$IP6" >> "$WORKDATA"
done

# --- Tạo cấu hình 3proxy ---
{
  echo "daemon"
  echo "maxconn 10000"
  echo "nscache 65536"
  echo "timeouts 1 5 30 60 180 1800 15 60"
  echo "setgid 65535"
  echo "setuid 65535"
  echo "flush"
  echo "log $LOG_PATH"
  echo "logformat \"L%t.%ms %N.%p %E %U %C:%c %R:%r %O %I %h %T\""

  # users
  echo -n "users "
  awk -F "/" '{
    gsub(/[:\\]/, "\\\\&", $2);  # escape `:` và `\`
    printf "%s:CL:%s ", $1, $2
  }' "$WORKDATA"
  echo ""
  
  echo "auth strong"

  # rules
  awk -F "/" '{
    u=$1; p=$2; ip4=$3; port=$4; ip6=$5;
    print "allow " u
    print "proxy -n -a -p" port " -i0.0.0.0 -i:: -e" ip4 " -e" ip6
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
RestartSec=0
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# --- Mở firewall và iptables ---
if systemctl is-active --quiet firewalld; then
  for port in $(awk -F "/" '{print $4}' "$WORKDATA"); do
    firewall-cmd --permanent --add-port=${port}/tcp || true
  done
  firewall-cmd --reload || true
fi

for port in $(awk -F "/" '{print $4}' "$WORKDATA"); do
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

# --- Xuất proxy.txt (chỉ với IPv4) ---
while IFS="/" read -r USER PASS IP4 PORT IP6; do
  UE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
  PE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")
  echo "http://${UE}:${PE}@${IP4}:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Đã tạo $COUNT proxy IPv4 + IPv6, mỗi proxy dùng port riêng từ $BASE_PORT"
echo "📄 File proxy: $PROXY_TXT"
cat "$PROXY_TXT"
echo "Install Done"
