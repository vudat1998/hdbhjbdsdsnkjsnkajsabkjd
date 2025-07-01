#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Kiểm tra tham số truyền vào
if [ -z "$1" ]; then
    echo "❌ Bạn phải truyền IP VPS vào! (ví dụ: bash script.sh 123.123.123.123)"
    exit 1
fi

IP4="$1"
echo "✅ Dùng IPv4 được truyền vào: $IP4"

# Random port và user/pass
PORT1=$((RANDOM % 10000 + 10000))
PORT2=$((RANDOM % 10000 + 20000))
USER1=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
PASS1=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
USER2=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
PASS2=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)

# Ghi data.txt: user/pass/ip/port/ip
echo "$USER1/$PASS1/$IP4/$PORT1/$IP4" > "$WORKDATA"
echo "$USER2/$PASS2/$IP4/$PORT2/$IP4" >> "$WORKDATA"

# Tạo cấu hình 3proxy
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

# 🔓 Mở port firewall-cmd (nếu có firewalld)
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port firewall..."
    firewall-cmd --permanent --add-port=${PORT1}/tcp || true
    firewall-cmd --permanent --add-port=${PORT2}/tcp || true
    firewall-cmd --reload || true
fi

# 🔓 Mở port iptables (phòng trường hợp không dùng firewalld)
echo "🛡️  Thêm iptables rule..."
iptables -I INPUT -p tcp --dport ${PORT1} -j ACCEPT
iptables -I INPUT -p tcp --dport ${PORT2} -j ACCEPT

# Khởi động lại 3proxy
echo "🔁 Khởi động lại 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "✅ Hoàn tất tạo proxy IPv4!"
echo "Install Done"
