#!/bin/bash
set -e

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

mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%&^_+-'

# --- Tìm interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "✅ Sử dụng interface: $NET_IF"

# --- Hàm sinh IPv6 ngẫu nhiên ---
generate_ipv6() {
  echo "${IPV6_PREFIX}:$(xxd -l 8 -p /dev/urandom \
    | sed 's/../&:/g; s/:$//; s/\(..\):\(..\)/\1\2/g')"
}

# --- Tạo proxy ---
for i in $(seq 1 "$COUNT"); do
  PORT=$((BASE_PORT + i - 1))
  USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c8)
  PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
  IP6=$(generate_ipv6)

  # Gán IPv6 vào interface nếu chưa có
  ip -6 addr add "${IP6}/64" dev "$NET_IF" || true

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

  # users
  echo -n "users "
  awk -F "/" '{ printf "%s:CL:%s ", $1, $2 }' "$WORKDATA"
  echo ""
  
  echo "auth strong"

  # rules
  awk -F "/" '{
    u=$1; p=$2; ip4=$3; port=$4; ip6=$5;
    print "allow " u
    print "proxy -n -a -p" port " -i" ip4 " -e" ip4
    print "allow " u
    print "proxy -6 -n -a -p" port " -i[" ip6 "] -e[" ip6 "]"
  }' "$WORKDATA"
} > "$CONFIG_PATH"

chmod 644 "$CONFIG_PATH"

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

# --- Xuất proxy.txt ---
while IFS="/" read -r USER PASS IP4 PORT IP6; do
  UE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
  PE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")
  echo "http://${UE}:${PE}@${IP4}:${PORT}" >> "$PROXY_TXT"
  echo "http://${UE}:${PE}@[${IP6}]:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Đã tạo $COUNT proxy IPv4 + IPv6, mỗi proxy dùng port riêng từ $BASE_PORT"
echo "📄 File proxy: $PROXY_TXT"
head -n "$((COUNT * 2))" "$PROXY_TXT"
echo "Install Done"
