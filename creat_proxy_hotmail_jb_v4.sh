#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

IP4=$(curl -4 -s ifconfig.me)

# Random port và user/pass
PORT1=$((RANDOM % 10000 + 10000))
PORT2=$((RANDOM % 10000 + 20000))
USER1=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
PASS1=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
USER2=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
PASS2=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)

# Ghi file data.txt (user/pass/ip/port)
echo "$USER1/$PASS1/$IP4/$PORT1/$IP4" > "$WORKDATA"
echo "$USER2/$PASS2/$IP4/$PORT2/$IP4" >> "$WORKDATA"

# Tạo file cấu hình 3proxy
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
} > /usr/local/etc/3proxy/3proxy.cfg

# Phân quyền file config
chmod 644 /usr/local/etc/3proxy/3proxy.cfg

# Ghi file proxy.txt cho user
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "${WORKDIR}/proxy.txt"

# Khởi động lại 3proxy
echo "==> Kích hoạt và khởi động dịch vụ 3proxy"
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "✅ Hoàn tất cài đặt proxy IPv4!"
echo "Install Done"
