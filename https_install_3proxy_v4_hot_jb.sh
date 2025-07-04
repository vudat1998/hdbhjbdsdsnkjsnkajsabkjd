#!/bin/bash

set -e

IPV4="$1"
if [[ -z "$IPV4" ]]; then
  echo "❌ Vui lòng truyền IPv4 vào làm đối số."
  echo "Ví dụ: bash https_create_2proxy.sh 64.176.37.43"
  exit 1
fi

CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
CERT_PATH="/usr/local/etc/3proxy/cert.pem"
KEY_PATH="/usr/local/etc/3proxy/key.pem"
LOG_DIR="/usr/local/etc/3proxy/logs"
PLUGIN_PATH="/usr/local/3proxy/libexec/SSLPlugin.ld.so"

# 1) Tạo thư mục log và phân quyền
mkdir -p "$LOG_DIR"
chown nobody:nobody "$LOG_DIR"
chmod 755 "$LOG_DIR"

# 2) Tạo cert nếu chưa có
echo "🔐 Kiểm tra SSL cert..."
if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$KEY_PATH" \
    -out "$CERT_PATH" \
    -subj "/CN=localhost"
  chown nobody:nobody "$CERT_PATH" "$KEY_PATH"
  chmod 640 "$CERT_PATH" "$KEY_PATH"
else
  echo "✅ SSL cert đã tồn tại"
fi

# 3) Hàm random port và user/pass
gen_port() {
  while :; do
    port=$((RANDOM % 50000 + 10000))
    ss -tnlp | grep -q ":$port" || break
  done
  echo "$port"
}

gen_userpass() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 6
}

# 4) Tạo user/pass/port
USER1="user$(gen_userpass)"
PASS1="pass$(gen_userpass)"
PORT1=$(gen_port)

USER2="user$(gen_userpass)"
PASS2="pass$(gen_userpass)"
PORT2=$(gen_port)

# 5) Ghi file cấu hình
echo "📄 Đang ghi cấu hình vào $CONFIG_PATH"

cat > "$CONFIG_PATH" <<EOF
nserver 8.8.8.8
nserver 8.8.4.4

# Không dùng 'daemon' để chạy foreground

maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush

# Logging (tuỳ chọn)
log $LOG_DIR/3proxy.log D
logformat "L%t %U %C %R %O %I %h %T"

# Load plugin và bật HTTPS proxy
plugin $PLUGIN_PATH ssl_plugin
ssl_server_cert $CERT_PATH
ssl_server_key  $KEY_PATH
ssl_serv

# Xác thực
auth strong
users $USER1:CL:$PASS1 $USER2:CL:$PASS2

# Hai HTTPS proxy
proxy -n -a -p$PORT1 -i$IPV4 -e$IPV4
proxy -n -a -p$PORT2 -i$IPV4 -e$IPV4

# Nếu cần thêm HTTP proxy:
ssl_noserv
# proxy -n -a -p3128 -i$IPV4 -e$IPV4
EOF

# 6) Mở port trên firewall/iptables
echo "🛡️ Mở firewall & iptables..."
firewall-cmd --permanent --add-port=$PORT1/tcp || true
firewall-cmd --permanent --add-port=$PORT2/tcp || true
firewall-cmd --reload || true
iptables -I INPUT -p tcp --dport $PORT1 -j ACCEPT
iptables -I INPUT -p tcp --dport $PORT2 -j ACCEPT

# 7) Reload systemd và restart 3proxy
echo "🔁 Khởi động lại 3proxy..."
systemctl daemon-reload
systemctl restart 3proxy

# 8) Kiểm tra trạng thái và ports
systemctl status 3proxy --no-pager | head -n 10
ss -tnlp | grep 3proxy || true

# 9) Hiển thị kết quả
echo "✅ Hoàn tất! Proxy HTTPS đã được tạo:"
echo "➡️ 1: https://$IPV4:$PORT1  |  $USER1 / $PASS1"
echo "➡️ 2: https://$IPV4:$PORT2  |  $USER2 / $PASS2"
