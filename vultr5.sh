#!/bin/bash
#
# install_centos9.sh
# Script cài đặt 3proxy và cấu hình tạo proxy IPv6 trên CentOS 9 Stream x64
# Hỗ trợ tự động phát hiện interface, mở firewall, thêm/xóa IPv6, và tạo file proxy cho user.
#

set -e

# 1. Cài đặt các package cần thiết
echo "==> Cài đặt dependencies với dnf"
dnf install -y gcc make wget bsdtar zip epel-release
dnf install -y iproute iptables iptables-services firewalld policycoreutils-python-utils

# 2. Kích hoạt và chạy firewalld (nếu chưa chạy)
if ! systemctl is-active --quiet firewalld; then
    echo "==> Bật và khởi động firewalld"
    systemctl enable firewalld
    systemctl start firewalld
fi

# 3. Kiểm tra SELinux: nếu đang ở chế độ Enforcing, chuyển sang Permissive (hoặc tạo policy cho 3proxy)
SELINUX_STATUS=$(getenforce)
if [ "$SELINUX_STATUS" == "Enforcing" ]; then
    echo "==> SELinux đang ở chế độ Enforcing – tạm chuyển thành Permissive để tránh chặn 3proxy"
    setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi

# 4. Phát hiện interface mạng IPv4 mặc định (ví dụ ens3, enp1s0, v.v.)
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$IFACE" ]; then
    echo "Lỗi: Không phát hiện được interface mạng IPv4 mặc định."
    exit 1
fi
echo "==> Giao diện mạng IPv4 mặc định: $IFACE"

# 5. Hàm tạo chuỗi ngẫu nhiên 5 ký tự (A-Za-z0-9)
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# 6. Mảng hex để sinh địa chỉ IPv6 (mỗi block 4 hex)
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# 7. Thư mục làm việc chung
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# 8. Lấy IPv4 & IPv6 hiện tại
IP4=$(curl -4 -s icanhazip.com)
# Lấy 4 block đầu của IPv6 gốc (phần subnet /64)
IP6_FULL=$(curl -6 -s icanhazip.com)
# Cắt lấy 4 block đầu tiên (ví dụ 2001:db8:abcd:1234)
IP6=$(echo "$IP6_FULL" | cut -f1-4 -d':')

if [ -z "$IP4" ] || [ -z "$IP6" ]; then
    echo "Lỗi: Không lấy được IPv4 hoặc IPv6 từ icanhazip.com"
    exit 1
fi
echo "==> Địa chỉ IPv4 máy chủ: $IP4"
echo "==> Phần subnet IPv6 (4 block đầu): $IP6"

COUNT=100
echo "==> Số lượng proxy mặc định: $COUNT"

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

echo "==> Khoảng port sẽ dùng: $FIRST_PORT ... $LAST_PORT"

# 10. Sinh dữ liệu (user/pass/IP4/port/IPv6) và lưu vào WORKDATA
echo "==> Tạo danh sách tài khoản và địa chỉ proxy..."
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 "$IP6")"
    done
}
gen_data >"$WORKDATA"

# 11. Mở port hàng loạt trên firewalld: dải FIRST_PORT-LAST_PORT (TCP)
echo "==> Mở firewall cho các port proxy trên firewalld..."
if firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port="${FIRST_PORT}-${LAST_PORT}"/tcp
    firewall-cmd --reload
else
    echo "Chú ý: firewalld chưa chạy, bạn cần mở port thủ công hoặc bật firewalld trước."
fi

# 12. Thêm địa chỉ IPv6 lên interface (block /64) cho mỗi proxy
#    Tạo script boot_ifconfig.sh và boot_ifconfig_delete.sh để tái khởi động nếu cần
echo "==> Tạo script thêm/xóa IPv6 cho interface..."
cat >"${WORKDIR}/boot_ifconfig.sh" <<EOF
#!/bin/bash
# Thêm từng IPv6 /64 lên interface $IFACE
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr add \$ipv6/64 dev $IFACE
done < "$WORKDATA"
EOF

cat >"${WORKDIR}/boot_ifconfig_delete.sh" <<EOF
#!/bin/bash
# Xóa từng IPv6 khỏi interface $IFACE
while IFS="/" read -r _ _ _ _ ipv6; do
    ip -6 addr del \$ipv6/64 dev $IFACE
done < "$WORKDATA"
EOF

chmod +x "${WORKDIR}/boot_ifconfig.sh" "${WORKDIR}/boot_ifconfig_delete.sh"

# Chạy ngay script thêm IPv6
bash "${WORKDIR}/boot_ifconfig.sh"

# 13. Cài đặt và biên dịch 3proxy
echo "==> Tải về và cài đặt 3proxy v0.9.4"
THIRD_URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
wget -qO- "$THIRD_URL" | bsdtar -xvf- >/dev/null
cd 3proxy-0.9.4
make -f Makefile.Linux

# Tạo cấu trúc thư mục cho 3proxy
mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
cp bin/3proxy /usr/local/etc/3proxy/bin/
cp scripts/3proxy.service /etc/systemd/system/3proxy.service

# Sửa lại đường dẫn CONFIGFILE và ExecStart trong service
sed -i 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
sed -i 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' /etc/systemd/system/3proxy.service
sed -i 's|RestartSec=60s|RestartSec=0s|' /etc/systemd/system/3proxy.service

chmod +x /usr/local/etc/3proxy/bin/3proxy
cd "$WORKDIR"

# 14. Tạo file cấu hình 3proxy (3proxy.cfg) dựa trên WORKDATA
echo "==> Tạo file cấu hình 3proxy (/usr/local/etc/3proxy/3proxy.cfg)..."
cat > /usr/local/etc/3proxy/3proxy.cfg <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush

# Định nghĩa user/pass
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")

# Cho phép từng user, thiết lập proxy -6
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' "$WORKDATA")
EOF

chmod +x /usr/local/etc/3proxy/3proxy.cfg

# 15. Tạo file proxy.txt để user có thể download/kiểm tra
echo "==> Tạo proxy.txt cho user sử dụng"
cat > "${WORKDIR}/proxy.txt" <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "$WORKDATA")
EOF

# 16. Khởi động 3proxy và enable service
echo "==> Kích hoạt và khởi động dịch vụ 3proxy"
systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

echo "==> Hoàn tất cài đặt!"
echo "- File proxy cho user: ${WORKDIR}/proxy.txt"
echo "- Nếu bạn khởi động lại máy, hãy chạy:"
echo "    bash ${WORKDIR}/boot_ifconfig.sh"
echo "  để thêm lại địa chỉ IPv6."
echo "- Nếu muốn xóa IPv6 (trước khi chạy script xoá):"
echo "    bash ${WORKDIR}/boot_ifconfig_delete.sh"
