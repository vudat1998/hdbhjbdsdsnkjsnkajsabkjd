#!/bin/bash
set -e

# --- KIỂM TRA ĐỐI SỐ ---
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "❌ Bạn phải truyền IPv4 và IPv6 prefix!"
    echo "   Cú pháp: bash $0 <IPv4> <IPv6_PREFIX>"
    echo "   Ví dụ:  bash $0 45.76.215.61 2001:19f0:7002:0c3a"
    exit 1
fi

IPV4="$1"
IPV6_PREFIX="$2"

# --- CẤU HÌNH ---
COUNT=10               # Số lượng proxy
PORT=30000             # Cổng dùng chung

# --- KHỞI TẠO ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

CHARS='A-Za-z0-9@%&^_+=-'

# Interface mạng
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "✅ Interface: $NET_IF"
echo "✅ IPv4: $IPV4"
echo "✅ IPv6 Prefix: ${IPV6_PREFIX}::/64"

# --- HÀM SINH IP ---
generate_ipv6() {
    echo "${IPV6_PREFIX}:$(xxd -l 8 -p /dev/urandom | sed 's/../&:/g; s/:$//; s/\(..\):\(..\)/\1\2/g')"
}

# --- TẠO PROXY ---
for i in $(seq 1 "$COUNT"); do
    USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c8)
    PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10)
    IP6=$(generate_ipv6)

    ip -6 addr add "${IP6}/64" dev "$NET_IF" || true

    echo "$USER/$PASS/$IPV4/$PORT/$IP6" >> "$WORKDATA"
done

# --- CẤU HÌNH 3PROXY ---
{
  echo "daemon"
  echo "maxconn 1000"
  echo "nscache 65536"
  echo "timeouts 1 5 30 60 180 1800 15 60"
  echo "setgid 65535"
  echo "setuid 65535"
  echo "flush"

  echo -n "users "
  awk -F "/" '{printf "%s:CL:%s ", $1, $2}' "$WORKDATA"
  echo ""
  echo "auth strong"

  awk -F "/" '{
    print "allow " $1
    print "proxy -n -a -p" $4 " -i" $3 " -e" $3
    print "allow " $1
    print "proxy -6 -n -a -p" $4 " -i[" $5 "] -e[" $5 "]"
  }' "$WORKDATA"
} > "$CONFIG_PATH"

chmod 644 "$CONFIG_PATH"

# --- FIREWALL ---
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port firewalld..."
    firewall-cmd --permanent --add-port=${PORT}/tcp || true
    firewall-cmd --reload || true
fi

echo "🛡️  Thêm rule iptables..."
iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT || true
ip6tables -I INPUT -p tcp --dport ${PORT} -j ACCEPT || true

# --- KHỞI ĐỘNG ---
echo "🔁 Restart 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

# --- EXPORT proxy.txt ---
while IFS="/" read -r USER PASS IP4 PORT IP6; do
    USER_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
    PASS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")
    echo "http://${USER_ENC}:${PASS_ENC}@${IP4}:${PORT}" >> "$PROXY_TXT"
    echo "http://${USER_ENC}:${PASS_ENC}@[${IP6}]:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Đã tạo $COUNT proxy IPv4/IPv6 dùng port $PORT!"
cat "$PROXY_TXT"
echo "Install Done"
