#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
CERT_DIR="/usr/local/etc/3proxy"
SSL_CONF="${CERT_DIR}/sslplugin.conf"
CONFIG_PATH="${CERT_DIR}/3proxy.cfg"
PLUGIN_PATH="/usr/local/3proxy/libexec/SSLPlugin.ld.so"

# Tạo thư mục làm việc
mkdir -p "$WORKDIR"
mkdir -p "$CERT_DIR"
mkdir -p "$CERT_DIR/logs"
cd "$WORKDIR"

# Kiểm tra IP đầu vào
if [ -z "$1" ]; then
    echo "❌ Bạn phải truyền IP VPS vào! (ví dụ: bash $0 123.123.123.123)"
    exit 1
fi

IP4="$1"
echo "✅ Dùng IPv4: $IP4"

# Random 2 port
PORT1=$((RANDOM % 10000 + 10000))
PORT2=$((RANDOM % 10000 + 20000))

# Sinh 2 user/pass
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
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${CERT_DIR}/key.pem" \
        -out "${CERT_DIR}/cert.pem" \
        -subj "/CN=proxy.local"
    sudo chmod 600 "${CERT_DIR}/key.pem"
    sudo chmod 644 "${CERT_DIR}/cert.pem"
else
    echo "✅ Đã có cert.pem và key.pem"
fi

# Tạo file sslplugin.conf
cat <<EOF | sudo tee "$SSL_CONF"
ssl_server_cert ${CERT_DIR}/cert.pem
ssl_server_key ${CERT_DIR}/key.pem
ssl_server
EOF

# Tạo file cấu hình 3proxy.cfg
cat <<EOF | sudo tee "$CONFIG_PATH"
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
log ${CERT_DIR}/logs/3proxy.log D
logformat "L%t %U %C %R %O %I %h %T"
plugin ${PLUGIN_PATH} sslplugin_init
pluginconf ${SSL_CONF}
users $(awk -F "/" '{printf "%s:CL:%s ", $1, $2}' "$WORKDATA")
auth strong
$(awk -F "/" '{print "allow " $1 "\nproxy -n -a --ssl -p" $4 " -i" $3 " -e" $5}' "$WORKDATA")
EOF

sudo chmod 644 "$CONFIG_PATH"

# Xuất proxy.txt
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "${WORKDIR}/proxy.txt"

# Mở firewall nếu firewalld bật
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port trên firewalld..."
    sudo firewall-cmd --permanent --add-port=${PORT1}/tcp || true
    sudo firewall-cmd --permanent --add-port=${PORT2}/tcp || true
    sudo firewall-cmd --reload || true
fi

# Mở iptables
echo "🛡️ Thêm rule iptables..."
sudo iptables -I INPUT -p tcp --dport ${PORT1} -j ACCEPT
sudo iptables -I INPUT -p tcp --dport ${PORT2} -j ACCEPT

# Cập nhật file systemd
cat <<EOF | sudo tee /etc/systemd/system/3proxy.service
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

# Khởi động lại 3proxy
echo "🔁 Khởi động lại 3proxy..."
sudo systemctl daemon-reload
sudo systemctl enable 3proxy
sudo systemctl restart 3proxy

# Kiểm tra trạng thái
echo "🔍 Kiểm tra trạng thái 3proxy..."
sudo systemctl status 3proxy

echo "✅ Tạo proxy HTTPS thành công!"
cat "${WORKDIR}/proxy.txt"
echo "Install Done"
