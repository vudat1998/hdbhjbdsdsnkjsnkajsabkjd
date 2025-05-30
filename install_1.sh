#!/bin/sh

# Hàm kiểm tra và cài đặt iptables nếu chưa có
check_iptables_install() {
    if ! iptables -V &> /dev/null
    then
        echo "iptables chưa được cài đặt. Đang tiến hành cài đặt..."
        sudo yum install -y iptables-services
        sudo systemctl enable iptables
        sudo systemctl start iptables
    else
        echo "iptables đã được cài đặt."
    fi
}

# Hàm sinh chuỗi ngẫu nhiên
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Mảng cho việc sinh IPv6
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

# Hàm sinh địa chỉ IPv6
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Hàm cài đặt 3proxy
install_3proxy() {
    echo "installing 3proxy"
    URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.service /etc/systemd/system/3proxy.service
    sed -i 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
    sed -i 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' /etc/systemd/system/3proxy.service
    sed -i 's/RestartSec=60s/RestartSec=0s/' /etc/systemd/system/3proxy.service
    chmod +x /usr/local/etc/3proxy/bin/3proxy
    cd $WORKDIR
}

# Hàm sinh cấu hình 3proxy
gen_3proxy() {
    cat <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})
$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# Hàm sinh tệp proxy cho người dùng
gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

# Hàm upload proxy (chưa triển khai)
upload_proxy() {
    echo "upload"
}

# Hàm sinh dữ liệu proxy
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# Hàm sinh lệnh iptables để thêm quy tắc
gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA})
EOF
}

# Hàm sinh lệnh iptables để xóa quy tắc
gen_iptables_delete() {
    cat <<EOF
$(awk -F "/" '{print "iptables -D INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA})
EOF
}

# Hàm sinh lệnh ifconfig để thêm IPv6
gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

# Hàm sinh lệnh ifconfig để xóa IPv6
gen_ifconfig_delete() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64"}' ${WORKDATA})
EOF
}

# Phần dọn dẹp trước khi cài đặt
cleanup_3proxy() {
    echo "Đang dọn dẹp 3proxy cũ..."
    
    # Dừng và vô hiệu hóa dịch vụ 3proxy nếu tồn tại
    sudo systemctl stop 3proxy 2>/dev/null
    sudo systemctl disable 3proxy 2>/dev/null
    sudo rm -f /etc/systemd/system/3proxy.service 2>/dev/null
    sudo systemctl daemon-reload 2>/dev/null
    
    # Xóa các tệp và thư mục của 3proxy
    sudo rm -rf /usr/local/etc/3proxy 2>/dev/null
    sudo rm -rf /home/proxy-installer/3proxy-0.9.4 2>/dev/null
    
    # Xóa thư mục làm việc nếu tồn tại
    sudo rm -rf /home/proxy-installer 2>/dev/null
    
    # Xóa các quy tắc iptables cũ nếu script xóa tồn tại
    if [ -f /home/proxy-installer/boot_iptables_delete.sh ]; then
        bash /home/proxy-installer/boot_iptables_delete.sh
    else
        echo "Không tìm thấy boot_iptables_delete.sh, bỏ qua việc xóa quy tắc iptables."
    fi
    sudo service iptables save 2>/dev/null || echo "Lưu iptables thất bại, có thể không cần thiết."
    
    # Xóa các địa chỉ IPv6 cũ nếu script xóa tồn tại
    if [ -f /home/proxy-installer/boot_ifconfig_delete.sh ]; then
        bash /home/proxy-installer/boot_ifconfig_delete.sh
    else
        echo "Không tìm thấy boot_ifconfig_delete.sh, bỏ qua việc xóa địa chỉ IPv6."
    fi
    
    # Dọn dẹp các tệp còn sót lại
    sudo find /usr/local/etc -name "*3proxy*" -exec rm -rf {} \; 2>/dev/null
    
    echo "Đã hoàn tất dọn dẹp 3proxy cũ."
}

# Bắt đầu script chính
echo "Bắt đầu quá trình cài đặt 3proxy..."

# Dọn dẹp 3proxy cũ trước khi cài đặt
cleanup_3proxy

# Cài đặt các ứng dụng cần thiết
echo "installing apps"
yum -y install gcc net-tools bsdtar zip >/dev/null

# Kiểm tra và cài đặt iptables nếu cần
check_iptables_install

# Cài đặt 3proxy
install_3proxy

# Thiết lập thư mục làm việc
echo "working folder = /home/proxy-installer"
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $_

# Lấy địa chỉ IP
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

# Nhập số lượng proxy cần tạo
echo "How many proxy do you want to create? Example 500"
read COUNT

# Thiết lập cổng
FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT))

# Sinh dữ liệu proxy
gen_data >$WORKDIR/data.txt

# Sinh các script boot
gen_iptables_delete > $WORKDIR/boot_iptables_delete.sh
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig_delete >$WORKDIR/boot_ifconfig_delete.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x ${WORKDIR}/boot_*.sh

# Sinh cấu hình 3proxy
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg
chmod 644 /usr/local/etc/3proxy/3proxy.cfg  # Đổi từ +x sang 644 để phù hợp với tệp cấu hình

# Thực thi các script boot
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh

# Thiết lập ulimit
ulimit -n 10048

# Sinh tệp proxy cho người dùng
gen_proxy_file_for_user

# Khởi động dịch vụ 3proxy
systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

echo "Install Done"
