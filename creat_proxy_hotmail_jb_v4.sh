#!/bin/bash
set -e
echo "new1"
# --- Cấu hình chính ---
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXY_TXT="${WORKDIR}/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
BASE_PORT=10000
NUM_PROXIES=10         # Số proxy cần sinh
SPECIAL_CHARS='A-Za-z0-9@%&^_+='

# --- Tạo thư mục & chuyển vào ---
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# --- Đọc tham số IPv4 và IPv6 prefix ---
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "❌ Cú pháp: bash $0 <IPv4> <IPv6_PREFIX>"
  echo "   VD: bash $0 45.76.215.61 2001:19f0:7002:0c3a"
  exit 1
fi
IP4="$1"
IP6_PREFIX="$2"
echo "✅ IPv4: $IP4"
echo "🌐 IPv6 prefix: ${IP6_PREFIX}::/64"

# --- Reset dữ liệu cũ ---
> "$WORKDATA"
> "$PROXY_TXT"

# --- Phát hiện interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "🔍 Interface mạng: $NET_IF"

# --- Hàm sinh IPv6 đúng chuẩn ---
generate_ipv6() {
  echo "${IP6_PREFIX}:$(xxd -l 8 -p /dev/urandom | sed 's/../&:/g; s/:$//; s/\(..\):\(..\)/\1\2/g')"
}

# --- Sinh danh sách proxy (user/pass + IP4 + port + IP6) ---
for i in $(seq 1 $NUM_PROXIES); do
  PORT=$((BASE_PORT + i))
  USER=$(tr -dc "$SPECIAL_CHARS" </dev/urandom | head -c8)
  PASS=$(tr -dc "$SPECIAL_CHARS" </dev/urandom | head -c10)
  IP6=$(generate_ipv6)
  echo "$USER/$PASS/$IP4/$PORT/$IP6" >> "$WORKDATA"
done

# --- Gán tất cả IPv6 vào interface để 3proxy bind được ---
while IFS="/" read -r _ _ _ _ IP6; do
  ip -6 addr add "${IP6}/64" dev "$NET_IF" || true
done < "$WORKDATA"

# --- Tạo file cấu hình 3proxy ---
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
  # proxy rules
  awk -F "/" '{
    user=$1; pass=$2; ip4=$3; port=$4; ip6=$5;
    # IPv4
    print "allow " user
    print "proxy -n -a -p" port " -i" ip4 " -e" ip4
    # IPv6 (bao ngoặc vuông)
    print "allow " user
    print "proxy -6 -n -a -p" port " -i[" ip6 "] -e[" ip6 "]"
  }' "$WORKDATA"
} > "$CONFIG_PATH"

chmod 644 "$CONFIG_PATH"

# --- Mở port firewall (firewalld) ---
if systemctl is-active --quiet firewalld; then
  for i in $(seq 1 $NUM_PROXIES); do
    P=$((BASE_PORT + i))
    firewall-cmd --permanent --add-port=${P}/tcp || true
  done
  firewall-cmd --reload || true
fi

# --- Mở port iptables & ip6tables ---
for i in $(seq 1 $NUM_PROXIES); do
  P=$((BASE_PORT + i))
  iptables -I INPUT -p tcp --dport ${P} -j ACCEPT || true
  ip6tables -I INPUT -p tcp --dport ${P} -j ACCEPT || true
done

# --- Restart 3proxy để áp dụng cấu hình mới ---
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

# --- Xuất proxy.txt chuẩn URL ---
while IFS="/" read -r USER PASS IP4 PORT IP6; do
  USER_ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote('''$USER'''))")
  PASS_ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote('''$PASS'''))")
  echo "http://${USER_ENC}:${PASS_ENC}@${IP4}:${PORT}" >> "$PROXY_TXT"
  echo "http://${USER_ENC}:${PASS_ENC}@[${IP6}]:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Tạo $NUM_PROXIES proxy hỗn hợp IPv4/IPv6 thành công!"
echo "📄 File proxy: $PROXY_TXT"
head -n 5 "$PROXY_TXT"
echo "Install Done"
