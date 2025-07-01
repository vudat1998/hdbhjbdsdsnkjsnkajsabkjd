#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ -z "$1" ]; then
    echo "❌ Bạn phải truyền IP VPS vào! (ví dụ: bash $0 123.123.123.123)"
    exit 1
fi

IP4="$1"
echo "✅ Dùng IPv4: $IP4"

# Random 2 port
PORT1=$((RANDOM % 10000 + 10000))
PORT2=$((RANDOM % 10000 + 20000))

# Sinh 2 user/pass (userXYZ/passXYZ)
ID1=$(tr -dc A-Za-z0-9 </dev/urandom | head -c5)
USER1="user${ID1}"
PASS1="pass${ID1}"

ID2=$(tr -dc A-Za-z0-9 </dev/urandom | head -c5)
USER2="user${ID2}"
PASS2="pass${ID2}"

# Ghi file data.txt (user/pass/ip/port/ip)
echo "$USER1/$PASS1/$IP4/$PORT1/$IP4" > "$WORKDATA"
echo "$USER2/$PASS2/$IP4/$PORT2/$IP4" >> "$WORKDATA"

# Tạo cấu hình 3proxy.cfg
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
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
  awk -F "/" '{print "allow " $1 "\nproxy -n -a -p" $4 " -i" $3 " -e" $5}' "$WORKDATA"
} > "$CONFIG_PATH"

chmod 644 "$CONFIG_PATH"

# Xuất proxy.txt
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "${WORKDIR}/proxy.txt"

# Mở firewall nếu firewalld bật
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port trên firewalld..."
    firewall-cmd --permanent --add-port=${PORT1}/tcp || true
    firewall-cmd --permanent --add-port=${PORT2}/tcp || true
    firewall-cmd --reload || true
fi

# Mở iptables nếu cần
echo "🛡️  Thêm rule iptables..."
iptables -I INPUT -p tcp --dport ${PORT1} -j ACCEPT
iptables -I INPUT -p tcp --dport ${PORT2} -j ACCEPT

# Restart 3proxy
echo "🔁 Khởi động lại 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "✅ Tạo proxy IPv4 thành công!"
cat "${WORKDIR}/proxy.txt"
echo "Install Done"
