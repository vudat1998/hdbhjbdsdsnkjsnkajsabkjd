#!/bin/bash

set -e

echo "==> Cài đặt dependencies"
dnf install -y gcc make wget bsdtar zip epel-release
dnf install -y iproute iptables iptables-services firewalld policycoreutils-python-utils curl

systemctl enable firewalld --now || true

SELINUX_STATUS=$(getenforce)
if [ "$SELINUX_STATUS" == "Enforcing" ]; then
    setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi

IFACE=$(ip -o -4 route show to default | awk '{print $5}')
[ -z "$IFACE" ] && echo "❌ Không tìm được interface" && exit 1

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
[ -z "$IP4" ] || [ -z "$IP6" ] && echo "❌ Không lấy được IP" && exit 1

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "==> Nhập số lượng proxy muốn tạo:"
read -r COUNT
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "❌ Số không hợp lệ"; exit 1; }

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

# Gen ngẫu nhiên
random() { tr </dev/urandom -dc A-Za-z0-9 | head -c5; echo; }
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Gen proxy data
seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
    echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6")"
done > "$WORKDATA"

# Tạo script thêm/xóa IPv6
cat >"${WORKDIR}/boot_ifconfig.sh" <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr add \$ipv6/64 dev $IFACE
done < "$WORKDATA"
EOF

cat >"${WORKDIR}/boot_ifconfig_delete.sh" <<EOF
#!/bin/bash
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr del \$ipv6/64 dev $IFACE
done < "$WORKDATA"
EOF
chmod +x "${WORKDIR}/boot_ifconfig.sh" "${WORKDIR}/boot_ifconfig_delete.sh"
bash "${WORKDIR}/boot_ifconfig.sh"

# Mở firewall port
firewall-cmd --permanent --add-port="${FIRST_PORT}-${LAST_PORT}/tcp" || true
firewall-cmd --reload || true

# Cài đặt 3proxy
wget -qO- "https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz" | bsdtar -xvf- >/dev/null
cd 3proxy-0.9.4
make -f Makefile.Linux
mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
cp bin/3proxy /usr/local/etc/3proxy/bin/
cp scripts/3proxy.service /etc/systemd/system/3proxy.service
sed -i 's|CONFIGFILE=/etc/3proxy/3proxy.cfg|CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
sed -i 's|ExecStart=/bin/3proxy|ExecStart=/usr/local/etc/3proxy/bin/3proxy|' /etc/systemd/system/3proxy.service
chmod +x /usr/local/etc/3proxy/bin/3proxy
cd "$WORKDIR"

# Tạo cấu hình 3proxy
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
  echo "allow *"
  awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' "$WORKDATA"
} > /usr/local/etc/3proxy/3proxy.cfg

chmod 644 /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA" > "${WORKDIR}/proxy.txt"

systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

echo "✅ Cài đặt hoàn tất!"
echo "- Danh sách proxy: ${WORKDIR}/proxy.txt"
echo "- Chạy lại sau reboot: bash ${WORKDIR}/boot_ifconfig.sh"
