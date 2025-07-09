#!/bin/bash
set -e

# --- Kiểm tra 3proxy đã cài đặt chưa ---
if ! [ -f /usr/local/etc/3proxy/bin/3proxy ]; then
  echo "❌ 3proxy không được cài đặt ở /usr/local/etc/3proxy/bin/3proxy."
  echo "Chạy script cài đặt 3proxy trước khi tiếp tục."
  exit 1
fi

# # --- Kiểm tra tài nguyên hệ thống ---
# MEM_AVAILABLE=$(free -m | awk '/Mem:/ {print $7}')
# if [ "$MEM_AVAILABLE" -lt 500 ]; then
#   echo "⚠️ Bộ nhớ khả dụng thấp ($MEM_AVAILABLE MB). Cần ít nhất 500 MB để chạy ổn định."
#   exit 1
# fi

# --- Tăng ulimits nếu cần ---
CURRENT_ULIMIT=$(ulimit -n)
if [ "$CURRENT_ULIMIT" -lt 20000 ]; then
  echo "⚠️ ulimits quá thấp ($CURRENT_ULIMIT). Tăng lên 524288..."
  echo -e "* soft nofile 524288\n* hard nofile 524288" | sudo tee -a /etc/security/limits.conf
  sudo sed -i '/DefaultLimitNOFILE=/d' /etc/systemd/system.conf
  sudo sed -i '/DefaultLimitNOFILE=/d' /etc/systemd/user.conf
  echo "DefaultLimitNOFILE=524288:524288" | sudo tee -a /etc/systemd/system.conf
  echo "DefaultLimitNOFILE=524288:524288" | sudo tee -a /etc/systemd/user.conf
  sudo systemctl daemon-reexec
  ulimit -n 524288
  NEW_ULIMIT=$(ulimit -n)
  if [ "$NEW_ULIMIT" -lt 20000 ]; then
    echo "❌ Không thể đặt ulimits thành 524288 (hiện tại: $NEW_ULIMIT)."
    echo "Hãy đăng xuất và đăng nhập lại, hoặc chạy 'sudo reboot' và thử lại."
    exit 1
  fi
fi

# --- CẤU HÌNH ĐẦU VÀO ---
IPV4="$1"
IPV6_PREFIX="$2"
BASE_PORT="${3:-30000}"     # Mặc định 30000
COUNT="${4:-1000}"          # Mặc định 1000

# --- Thư mục lưu trữ ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"
LOG_PATH="/var/log/3proxy.log"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%^+'

# --- Tìm interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '/dev/ {print $5}')
if [ -z "$NET_IF" ]; then
  echo "❌ Không tìm thấy interface mạng."
  exit 1
fi
echo "✅ Sử dụng interface: $NET_IF"

# --- Mảng hex và hàm sinh đoạn IPv6 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

ip64() {
  echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
}

generate_ipv6() {
  echo "$IPV6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# --- Tạo proxy ---
for i in $(seq 1 "$COUNT"); do
  PORT=$((BASE_PORT + i - 1))

  # Tạo user có ít nhất 1 ký tự đặc biệt
  while true; do
    USER_RAW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c6 2>/dev/null || cat /dev/urandom | tr -dc A-Za-z0-9 | head -c6)
    SPECIAL=$(tr -dc '@%^+_' </dev/urandom | head -c2 2>/dev/null || cat /dev/urandom | tr -dc '@%^+_' | head -c2)
    USER="${USER_RAW}${SPECIAL}"
    echo "$USER" | grep -q '[@%^+]' && break
    sleep 0.01
  done

  # Tạo pass có ít nhất 1 ký tự đặc biệt
  while true; do
    PASS=$(tr -dc "$CHARS" </dev/urandom | head -c10 2>/dev/null || cat /dev/urandom | tr -dc "$CHARS" | head -c10)
    echo "$PASS" | grep -q '[@%^+]' && break
    sleep 0.01
  done

  IP6=$(generate_ipv6)

  # Gán IPv6 vào interface nếu chưa có
  if ! ip -6 addr show dev "$NET_IF" | grep -q "${IP6}/64"; then
    sudo ip -6 addr add "${IP6}/64" dev "$NET_IF" || {
      echo "⚠️ Không thể gán IPv6: $IP6, tiếp tục với IPv4..."
    }
  fi

  echo "$USER/$PASS/$IPV4/$PORT/$IP6" >> "$WORKDATA"
done

# --- Tạo cấu hình 3proxy ---
{
  echo "maxconn 10000"
  echo "nscache 65536"
  echo "timeouts 1 5 30 60 180 1800 15 60"
  echo "setgid 65535"
  echo "setuid 65535"
  echo "flush"

  # users
  echo -n "users "
  awk -F "/" '{
    gsub(/[:\\]/, "\\\\&", $2);  # escape `:` và `\`
    printf "%s:CL:%s ", $1, $2
  }' "$WORKDATA"
  echo ""
  
  echo "auth strong"

  # rules
  awk -F "/" '{
    u=$1; p=$2; ip4=$3; port=$4; ip6=$5;
    print "allow " u
    print "proxy -n -a -p" port " -i0.0.0.0 -i:: -e" ip4 " -e" ip6
  }' "$WORKDATA"
} > "$CONFIG_PATH"

sudo chmod 644 "$CONFIG_PATH"

# --- Sửa file dịch vụ systemd ---
cat << EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg
ExecStart=/usr/local/etc/3proxy/bin/3proxy \$CONFIGFILE
Restart=always
RestartSec=1
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# --- Mở firewall và iptables ---
if systemctl is-active --quiet firewalld; then
  for port in $(awk -F "/" '{print $4}' "$WORKDATA"); do
    firewall-cmd --permanent --add-port="${port}/tcp" || true
  done
  firewall-cmd --reload || true
fi

for port in $(awk -F "/" '{print $4}' "$WORKDATA"); do
  iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT || true
  ip6tables -I INPUT -p tcp --dport "${port}" -j ACCEPT || true
done

# --- Khởi động lại 3proxy ---
echo "🔁 Restart 3proxy..."
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

# --- Kiểm tra trạng thái 3proxy ---
if systemctl is-active --quiet 3proxy; then
  echo "✅ Dịch vụ 3proxy đang chạy."
else
  echo "❌ Dịch vụ 3proxy không chạy. Kiểm tra log bằng: journalctl -u 3proxy"
  exit 1
fi

# --- Xuất proxy.txt (chỉ với IPv4) ---
while IFS="/" read -r USER PASS IP4 PORT IP6; do
  UE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$USER'''))")
  PE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$PASS'''))")
  echo "http://${UE}:${PE}@${IP4}:${PORT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Đã tạo $COUNT proxy IPv4 (cổng $BASE_PORT-$((BASE_PORT+COUNT-1))) với ưu tiên xuất qua IPv4"
echo "📄 File: $PROXY_TXT"
cat "$PROXY_TXT"
echo "Install Done"
