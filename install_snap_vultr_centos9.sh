#!/bin/bash
# install_snap_vultr_centos9.sh
# Cài đặt gói cần thiết và biên dịch 3proxy, dùng để tạo snapshot CentOS 9
# curl -fsSL https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/install_snap_vultr_centos9.sh | bash


set -e

echo "==> Cài đặt dependencies với dnf"
dnf install -y gcc make wget bsdtar zip epel-release git openssl-devel pam-devel
dnf install -y iproute iptables iptables-services firewalld policycoreutils-python-utils curl

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

if [ ! -f /usr/local/etc/3proxy/bin/3proxy ]; then
    echo "==> Tải và cài đặt 3proxy v0.9.4"
    THIRD_URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.5.tar.gz"
    wget -qO- "$THIRD_URL" | bsdtar -xvf- >/dev/null
    cd 3proxy-0.9.5
    make -f Makefile.Linux
    make -f Makefile.Linux allplugins
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.service /etc/systemd/system/3proxy.service

    sed -i 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
    sed -i 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' /etc/systemd/system/3proxy.service
    sed -i 's|RestartSec=60s|RestartSec=0s|' /etc/systemd/system/3proxy.service
    
    chmod +x /usr/local/etc/3proxy/bin/3proxy
    cd /home/proxy-installer
    systemctl daemon-reexec
else
    echo "✅ 3proxy đã được cài đặt, bỏ qua bước cài."
fi

echo "✅ Cài xong gói và 3proxy – Sẵn sàng tạo snapshot!"
