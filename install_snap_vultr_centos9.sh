#!/bin/bash
# install_snap_vultr_centos9.sh
# Cài đặt gói cần thiết và biên dịch 3proxy, dùng để tạo snapshot CentOS 9
# curl -fsSL <URL> | bash

set -e

echo "==> Cài đặt dependencies với dnf"
dnf install -y gcc make wget bsdtar zip epel-release git openssl-devel pam-devel
dnf install -y iproute iptables iptables-services firewalld policycoreutils-python-utils curl openssl-libs

if ! systemctl is-active --quiet firewalld; then
    echo "==> Bật và khởi động firewalld"
    systemctl enable firewalld
    systemctl start firewalld
fi

SELINUX_STATUS=$(getenforce)
if [ "$SELINUX_STATUS" == "Enforcing" ]; then
    echo "==> SELinux đang ở Enforcing – chuyển thành Permissive"
    setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi

echo "==> Chuẩn bị thư mục /home/proxy-installer"
mkdir -p /home/proxy-installer
cd /home/proxy-installer

if [ ! -f /bin/3proxy ]; then
    echo "==> Tải và cài đặt 3proxy v0.9.5"
    THIRD_URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.5.tar.gz"
    wget -qO- "$THIRD_URL" | bsdtar -xvf- >/dev/null
    cd 3proxy-0.9.5
    make -f Makefile.Linux
    make -f Makefile.Linux allplugins
    sudo make -f Makefile.Linux install
    cd /home/proxy-installer
else
    echo "✅ 3proxy đã được cài đặt, bỏ qua bước cài."
fi

echo "==> Cập nhật file systemd"
cat <<EOF | sudo tee /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg
ExecStart=/bin/3proxy \$CONFIGFILE
Restart=always
RestartSec=3s
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Tải lại systemd"
sudo systemctl daemon-reload
sudo systemctl enable 3proxy

echo "✅ Cài xong gói và 3proxy – Sẵn sàng cấu hình proxy HTTPS!"
