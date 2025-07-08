#!/bin/bash
set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
PROXY_TXT="${WORKDIR}/proxy.txt"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ✅ Nhận IPv4 và IPv6 prefix từ đối số
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "❌ Bạn phải truyền IPv4 và IPv6 prefix vào!"
    echo "   Cú pháp: bash $0 <IPv4> <IPv6_PREFIX>"
    echo "   VD: bash $0 103.123.123.123 2a01:4f8:1c1a:abcd"
    exit 1
fi

IP4="$1"
IP6_PREFIX="$2"
echo "✅ IPv4: $IP4"
echo "🌐 IPv6 prefix: ${IP6_PREFIX}::/64"

# ✅ Reset file tạm
> "$WORKDATA"
> "$PROXY_TXT"

BASE_PORT=10000
SPECIAL_CHARS='A-Za-z0-9@%&^_+=-'  # ✅ ĐÃ SỬA lỗi tr

generate_ipv6() {
    r1=$(hexdump -n 2 -e '/1 "%04X"' /dev/urandom)
    r2=$(hexdump -n 2 -e '/1 "%04X"' /dev/urandom)
    r3=$(hexdump -n 2 -e '/1 "%04X"' /dev/urandom)
    r4=$(hexdump -n 2 -e '/1 "%04X"' /dev/urandom)
    echo "${IP6_PREFIX}:${r1}:${r2}:${r3}:${r4}"
}

# ✅ Sinh 1000 proxy
for i in $(seq 1 1000); do
    PORT=$((BASE_PORT + i))

    USER=$(tr -dc "$SPECIAL_CHARS" </dev/urandom | head -c8)
    PASS=$(tr -dc "$SPECIAL_CHARS" </dev/urandom | head -c10)
    IP6=$(generate_ipv6)

    echo "$USER/$PASS/$IP4/$PORT/$IP6" >> "$WORKDATA"
done

# ✅ Tạo cấu hình 3proxy
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

# ✅ Xuất proxy.txt đã mã hóa URL
while IFS="/" read -r USER PASS IP PORT IP6; do
    USER_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
    PASS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")
    echo "http://${USER_ENC}:${PASS_ENC}@${IP}:${PORT}" >> "$PROXY_TXT"
    echo "http://${USER_ENC}:${PASS_ENC}@[${IP6}]:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

# ✅ Mở port nếu có firewalld
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port trong firewalld..."
    for i in $(seq 1 1000); do
        PORT=$((BASE_PORT + i))
        firewall-cmd --permanent --add-port=${PORT}/tcp || true
    done
    firewall-cmd --reload || true
fi

# ✅ Mở port bằng iptables
echo "🛡️  Thêm rule iptables..."
for i in $(seq 1 1000); do
    PORT=$((BASE_PORT + i))
    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
done

# ✅ Restart 3proxy
echo "🔁 Khởi động lại 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "✅ Tạo 1000 proxy hỗn hợp IPv4/IPv6 thành công!"
echo "📄 File proxy: $PROXY_TXT"
cat "$PROXY_TXT" | head -n 5
echo "Install Done"
