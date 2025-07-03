#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
CERT_DIR="/usr/local/etc/3proxy"
SSL_CONF="${CERT_DIR}/sslplugin.conf"
CONFIG_PATH="${CERT_DIR}/3proxy.cfg"
PLUGIN_PATH="/usr/local/3proxy/libexec/SSLPlugin.ld.so"

mkdir -p "$WORKDIR"
mkdir -p "$CERT_DIR"
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

# Tạo chứng chỉ nếu chưa có
if [[ ! -f "${CERT_DIR}/cert.pem" || ! -f "${CERT_DIR}/key.pem" ]]; then
    echo "🔐 Đang tạo SSL cert..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${CERT_DIR}/key.pem" \
        -out "${CERT_DIR}/cert.pem" \
        -subj "/CN=proxy.local"
    chmod 600 "${CERT_DIR}/key.pem"
    chmod 644 "${CERT_DIR}/cert.pem"
else
    echo "✅ Đã có cert.pem và key.pem"
fi

# Tạo file sslplugin.conf
cat <<EOF > "$SSL_CONF"
ssl_server_cert ${CERT_DIR}/cert.pem
ssl_server_key ${CERT_DIR}/key.pem
ssl_server
EOF

# Tạo file cấu hình 3proxy.cfg
{
  echo "daemon"
  echo "maxconn 1000"
  echo "nscache 65536"
  echo "timeouts 1 5 30 60 180 1800 15 60"
  echo "setgid 65535"
  echo "setuid 65535"
  echo "flush"
  echo "log /usr/local/etc/3proxy/logs/3proxy.log D"
  echo "logformat \"L%t %U %C %R %O %I %h %T\""

  echo "plugin $PLUGIN_PATH sslplugin_init"
  echo "pluginconf $SSL_CONF"

  echo -n "users "
  awk -F "/" '{printf "%s:CL:%s ", $1, $2}' "$WORKDATA"
  echo ""

  echo "auth strong"
  awk -F "/" '{print "allow " $1 "\nproxy -n -a --ssl -p" $4 " -i" $3 " -e" $5}' "$WORKDATA"

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
echo "🛡️ Thêm rule iptables..."
iptables -I INPUT -p tcp --dport ${PORT1} -j ACCEPT
iptables -I INPUT -p tcp --dport ${PORT2} -j ACCEPT

# Sửa file systemd để trỏ đến cấu hình đúng
cat <<EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
Environment=CONFIGFILE=${CONFIG_PATH}
ExecStart=/bin/3proxy \$CONFIGFILE
Restart=always
RestartSec=0s

[Install]
WantedBy=multi-user.target
EOF

# Restart 3proxy
echo "🔁 Khởi động lại 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

# Kiểm tra trạng thái
echo "🔍 Kiểm tra trạng thái 3proxy..."
systemctl status 3proxy

echo "✅ Tạo proxy HTTPS thành công!"
cat "${WORKDIR}/proxy.txt"
echo "Install Done"
