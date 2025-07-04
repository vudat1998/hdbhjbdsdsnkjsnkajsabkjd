#!/bin/bash

set -e

WORKDIR="/home/proxy-installer"
BUILD_DIR="${WORKDIR}/3proxy-0.9.5"
WORKDATA="${WORKDIR}/data.txt"
CERT_DIR="/usr/local/etc/3proxy"
LIBEXEC_DIR="/usr/local/3proxy/libexec"
CONFIG_PATH="${CERT_DIR}/3proxy.cfg"
PLUGIN_SRC="${BUILD_DIR}/bin/SSLPlugin.ld.so"
PLUGIN_PATH="${LIBEXEC_DIR}/SSLPlugin.ld.so"

# 1. Chuẩn bị thư mục
mkdir -p "$WORKDIR"
mkdir -p "${CERT_DIR}/logs"
mkdir -p "${LIBEXEC_DIR}"
cd "$WORKDIR"

# 2. Kiểm tra IP đầu vào
if [ -z "$1" ]; then
    echo "❌ Bạn phải truyền IP VPS vào! (ví dụ: bash $0 123.123.123.123)"
    exit 1
fi
IP4="$1"
echo "✅ Dùng IPv4: $IP4"

# 3. Random port và user/pass
PORT1=$((RANDOM % 10000 + 10000))
PORT2=$((RANDOM % 10000 + 20000))
ID1=$(tr -dc A-Za-z0-9 </dev/urandom | head -c5)
ID2=$(tr -dc A-Za-z0-9 </dev/urandom | head -c5)
USER1="user${ID1}"; PASS1="pass${ID1}"
USER2="user${ID2}"; PASS2="pass${ID2}"

# 4. Ghi WORKDATA
cat > "$WORKDATA" <<EOF
$USER1/$PASS1/$IP4/$PORT1/$IP4
$USER2/$PASS2/$IP4/$PORT2/$IP4
EOF

# 5. Tạo cert nếu cần
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

# 6. Copy SSLPlugin và cấp quyền
if [ ! -f "${PLUGIN_SRC}" ]; then
    echo "❌ Không tìm thấy plugin ở ${PLUGIN_SRC}, vui lòng build 3proxy trước."
    exit 1
fi
sudo cp "${PLUGIN_SRC}" "${PLUGIN_PATH}"
sudo chmod 755 "${PLUGIN_PATH}"
sudo chown root:root "${PLUGIN_PATH}"

# 7. Tạo file cấu hình 3proxy.cfg
sudo tee "${CONFIG_PATH}" > /dev/null <<EOF
nserver 8.8.8.8
nserver 8.8.4.4

daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush

log ${CERT_DIR}/logs/3proxy.log D
logformat "L%t %U %C %R %O %I %h %T"

# Load SSLPlugin và bật HTTPS proxy
plugin ${PLUGIN_PATH} ssl_plugin
ssl_server_cert ${CERT_DIR}/cert.pem
ssl_server_key  ${CERT_DIR}/key.pem
ssl_serv

# User & auth
users $(awk -F "/" '{printf "%s:CL:%s ", $1, $2}' "${WORKDATA}")
auth strong

# Các proxy HTTPS tạo từ data.txt
$(awk -F "/" '{print "proxy -n -a -p"$4" -i"$3" -e"$5}' "${WORKDATA}")

# Chuyển về HTTP proxy (nếu cần)
ssl_noserv
# Ví dụ: proxy -n -a -p3128 -i${IP4} -e${IP4}
EOF

# 8. Thiết lập logs
sudo chown nobody:nobody "${CERT_DIR}/logs"
sudo touch "${CERT_DIR}/logs/3proxy.log"
sudo chown nobody:nobody "${CERT_DIR}/logs/3proxy.log"
sudo chmod 664 "${CERT_DIR}/logs/3proxy.log"

# 9. Xuất proxy.txt
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "${WORKDIR}/proxy.txt"

# 10. Mở port firewalld (nếu có)
if systemctl is-active --quiet firewalld; then
    echo "🔥 Mở port trên firewalld..."
    sudo firewall-cmd --permanent --add-port=${PORT1}/tcp || true
    sudo firewall-cmd --permanent --add-port=${PORT2}/tcp || true
    sudo firewall-cmd --reload || true
fi

# 11. Thêm rule iptables
echo "🛡️ Thêm rule iptables..."
sudo iptables -I INPUT -p tcp --dport ${PORT1} -j ACCEPT
sudo iptables -I INPUT -p tcp --dport ${PORT2} -j ACCEPT

# 12. Tạo service systemd và khởi động
sudo tee /etc/systemd/system/3proxy.service > /dev/null <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
Environment=CONFIGFILE=${CONFIG_PATH}
ExecStart=/usr/local/bin/3proxy \$CONFIGFILE
Restart=always
RestartSec=3s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

echo "🔁 Khởi động lại 3proxy..."
sudo systemctl daemon-reload
sudo systemctl enable 3proxy
sudo systemctl restart 3proxy

echo "🔍 Kiểm tra trạng thái 3proxy..."
sudo systemctl status 3proxy

echo "✅ Tạo proxy HTTPS thành công! File proxy.txt ở ${WORKDIR}/proxy.txt"
cat "${WORKDIR}/proxy.txt"
