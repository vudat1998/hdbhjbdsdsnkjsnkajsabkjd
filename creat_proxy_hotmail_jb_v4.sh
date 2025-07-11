#!/bin/bash
set -e

# --- Kiểm tra 3proxy đã cài đặt chưa ---
if ! [ -f /usr/local/etc/3proxy/bin/3proxy ]; then
  echo "❌ 3proxy không được cài đặt ở /usr/local/etc/3proxy/bin/3proxy." >&2
  echo "Chạy script cài đặt 3proxy trước khi tiếp tục." >&2
  exit 1
fi

# --- Tăng ulimits nếu cần ---
CURRENT_ULIMIT=$(ulimit -n)
if [ "$CURRENT_ULIMIT" -lt 20000 ]; then
  echo "⚠️ ulimits quá thấp ($CURRENT_ULIMIT). Tăng lên 524288..."
  echo -e "* soft nofile 524288\n* hard nofile 524288" | sudo tee -a /etc/security/limits.conf >/dev/null
  sudo sed -i '/DefaultLimitNOFILE=/d' /etc/systemd/system.conf
  sudo sed -i '/DefaultLimitNOFILE=/d' /etc/systemd/user.conf
  echo "DefaultLimitNOFILE=524288:524288" | sudo tee -a /etc/systemd/system.conf >/dev/null
  echo "DefaultLimitNOFILE=524288:524288" | sudo tee -a /etc/systemd/user.conf >/dev/null
  sudo systemctl daemon-reexec
  ulimit -n 524288 || true
  NEW_ULIMIT=$(ulimit -n)
  if [ "$NEW_ULIMIT" -lt 20000 ]; then
    echo "❌ Không thể đặt ulimits thành 524288 (hiện tại: $NEW_ULIMIT)." >&2
    echo "Hãy đăng xuất và đăng nhập lại, hoặc chạy 'sudo reboot' và thử lại." >&2
    exit 1
  fi
fi

# --- CẤU HÌNH ĐẦU VÀO ---
if [ $# -ne 6 ]; then
  echo "❌ Cú pháp: bash $0 <IPv4> <IPv6_PREFIX> <IPV4_BASE_PORT> <IPV6_BASE_PORT> <IPV4_COUNT> <IPV6_COUNT>" >&2
  exit 1
fi
IPV4="$1"; IPV6_PREFIX="$2"; IPV4_BASE_PORT="$3"; IPV6_BASE_PORT="$4"; IPV4_COUNT="$5"; IPV6_COUNT="$6"

for var in "$IPV4_BASE_PORT" "$IPV6_BASE_PORT" "$IPV4_COUNT" "$IPV6_COUNT"; do
  if [[ ! $var =~ ^[0-9]+$ ]]; then
    echo "❌ Các tham số BASE_PORT, COUNT phải là số nguyên!" >&2
    exit 1
  fi
done

# --- Thư mục lưu trữ ---
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXY_TXT="$WORKDIR/proxy.txt"
CONFIG_PATH="/usr/local/etc/3proxy/3proxy.cfg"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
> "$WORKDATA"
> "$PROXY_TXT"

# --- Tìm interface mạng chính ---
NET_IF=$(ip -4 route get 1.1.1.1 | awk '{print $5}')
echo "✅ Sử dụng interface: $NET_IF"

# --- Ký tự hợp lệ cho user/pass ---
CHARS='A-Za-z0-9@%&^_+-'

# --- Mảng hex và hàm sinh IPv6 ---
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
ip64() { echo "${array[$RANDOM%16]}${array[$RANDOM%16]}${array[$RANDOM%16]}${array[$RANDOM%16]}"; }
generate_ipv6() { echo "$IPV6_PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"; }

# --- Tạo proxy IPv4 ---
echo "✅ Tạo $IPV4_COUNT proxy IPv4..."
for i in $(seq 1 $IPV4_COUNT); do
  PORT=$((IPV4_BASE_PORT + i - 1))
  while :; do USER="$(tr -dc A-Za-z0-9 </dev/urandom | head -c6)$(tr -dc '@%&^_+-' </dev/urandom | head -c2)"; [[ $USER =~ [@%&^_+-] ]] && break; done
  while :; do PASS="$(tr -dc "$CHARS" </dev/urandom | head -c10)"; [[ $PASS =~ [@%&^_+-] ]] && break; done
  FALLBACK=$(generate_ipv6)
  echo "$USER/$PASS/$IPV4/$PORT/-/$FALLBACK" >> "$WORKDATA"
done

# --- Tạo proxy IPv6 ---
echo "✅ Tạo $IPV6_COUNT proxy IPv6..."
for i in $(seq 1 $IPV6_COUNT); do
  PORT=$((IPV6_BASE_PORT + i - 1))
  while :; do USER="$(tr -dc A-Za-z0-9 </dev/urandom | head -c6)$(tr -dc '@%&^_+-' </dev/urandom | head -c2)"; [[ $USER =~ [@%&^_+-] ]] && break; done
  while :; do PASS="$(tr -dc "$CHARS" </dev/urandom | head -c10)"; [[ $PASS =~ [@%&^_+-] ]] && break; done
  IP6=$(generate_ipv6)
  echo "$USER/$PASS/$IPV4/$PORT/$IP6/-" >> "$WORKDATA"
done

# --- Tạo script thêm IPv6 ---
cat > boot_ifconfig.sh <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ip6a ip6b; do
  for ip in "$ip6a" "$ip6b"; do
    [ "$ip" != "-" ] && ip -6 addr add "$ip/64" dev "$NET_IF" && echo "✅ Gán IPv6: $ip" || echo "⚠️ Không thể gán IPv6: $ip"
  done
done < "$WORKDATA"
EOF
chmod +x boot_ifconfig.sh
bash boot_ifconfig.sh

# --- Tạo cấu hình 3proxy ---
{
  echo "maxconn 10000"
  echo "nscache 65536"
  echo "timeouts 1 5 30 60 180 1800 15 60"
  echo "setgid 65535"
  echo "setuid 65535"
  echo "flush"
  echo -n "users "
  awk -F"/" '{gsub(/[:\\]/,"\\\\&",\$2); printf "%s:CL:%s ",\$1,\$2}' "$WORKDATA"
  echo
  echo "auth strong"
  echo "allow *"
  # IPv4-only: thêm IPv4 + fallback IPv6
  awk -F"/" '\$5=="-" {print "proxy -n -a -p"\$4" -i0.0.0.0 -i:: -e"\$3" -e"\$6}' "$WORKDATA"
  # IPv6-only: giữ nguyên
  awk -F"/" '\$5!="-" {print "proxy -6 -n -a -p"\$4" -i0.0.0.0 -e"\$5}' "$WORKDATA"
} > "$CONFIG_PATH"
chmod 644 "$CONFIG_PATH"

# --- Sửa systemd ---
cat > /etc/systemd/system/3proxy.service <<'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=always
RestartSec=1
KillMode=process
KillSignal=SIGKILL

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now 3proxy

# --- Mở firewall và iptables ---
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${IPV4_BASE_PORT}-$((IPV4_BASE_PORT+IPV4_COUNT-1))/tcp"
  firewall-cmd --permanent --add-port="${IPV6_BASE_PORT}-$((IPV6_BASE_PORT+IPV6_COUNT-1))/tcp"
  firewall-cmd --reload || true
fi
for port in $(awk -F"/" '{print \$4}' "$WORKDATA" | sort -u); do
  iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
  ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
done

# --- Xuất proxy.txt ---
while IFS="/" read -r U P I4 PRT _ _; do
  UE=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$U")
  PE=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$P")
  echo "${UE}:${PE}:${I4}:${PRT}" >> "$PROXY_TXT"
done < "$WORKDATA"

echo "✅ Hoàn tất!"; cat "$PROXY_TXT"
