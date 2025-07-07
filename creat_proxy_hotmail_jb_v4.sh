#!/bin/bash
set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
ENCODED_OUTPUT="${WORKDIR}/proxy_encoded.txt"
RAW_OUTPUT="${WORKDIR}/proxy.txt"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ -z "$1" ]; then
    echo "❌ Bạn phải truyền IP VPS vào! (VD: bash $0 123.123.123.123)"
    exit 1
fi

IP4="$1"
echo "✅ Dùng IPv4: $IP4"

# Lấy IPv6 prefix
IP6_PREFIX=$(ip -6 addr show dev eth0 | grep -oP '([0-9a-f]{1,4}:){3,6}' | head -n1)
if [ -z "$IP6_PREFIX" ]; then
    echo "❌ Không tìm được IPv6 prefix. Kiểm tra mạng."
    exit 1
fi

echo "🌐 IPv6 prefix: ${IP6_PREFIX}XXXX"

> "$WORKDATA"

BASE_PORT=10000
SPECIAL_CHARS='A-Za-z0-9@%&^_-+='

generate_ipv6() {
    echo "${IP6_PREFIX}$(hexdump -n 4 -e '/1 "%02X"' /dev/urandom | sed 's/../&:/g;s/:$//')"
}

for i in $(seq 1 1000); do
    PORT=$((BASE_PORT + i))

    USER=$(tr -dc "$SPECIAL_CHARS" </dev/urandom | head -c8)
    PASS=$(tr -dc "$SPECIAL_CHARS" </dev/urandom | head -c10)
    IP6=$(generate_ipv6)

    echo "$USER/$PASS/$IP4/$PORT/$IP6" >> "$WORKDATA"
done

# Ghi cấu hình 3proxy
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
{
  echo "daemon"
  echo "maxconn 10000"
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
    print "proxy -6 -n -a -p" $4 " -i" $5 " -e" $5
  }' "$WORKDATA"
} > "$CONFIG_PATH"

chmod 644 "$CONFIG_PATH"

# Tạo proxy.txt (raw) và proxy_encoded.txt
> "$RAW_OUTPUT"
> "$ENCODED_OUTPUT"

while IFS="/" read -r USER PASS IP PORT IP6; do
    echo "$IP:$PORT:$USER:$PASS" >> "$RAW_OUTPUT"
    
    # Encode USER/PASS
    USER_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
    PASS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")

    echo "http://${USER_ENC}:${PASS_ENC}@${IP}:${PORT}" >> "$ENCODED_OUTPUT"
done < "$WORKDATA"

# Mở firewall
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port trong firewalld..."
    for i in $(seq 1 1000); do
        PORT=$((BASE_PORT + i))
        firewall-cmd --permanent --add-port=${PORT}/tcp || true
    done
    firewall-cmd --reload || true
fi

# iptables fallback
echo "🛡️  Thêm iptables rules..."
for i in $(seq 1 1000); do
    PORT=$((BASE_PORT + i))
    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
done

# Restart 3proxy
echo "🔁 Khởi động lại 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "✅ Đã tạo xong 1000 proxy hỗn hợp IPv4/IPv6!"

echo "📦 proxy.txt (raw): $RAW_OUTPUT"
echo "🔐 proxy_encoded.txt (URL dùng được): $ENCODED_OUTPUT"
cat "$ENCODED_OUTPUT" | head -n 5
