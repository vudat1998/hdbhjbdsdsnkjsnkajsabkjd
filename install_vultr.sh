#!/bin/bash

# Updated for CentOS 9 Stream

set -e

check_firewall() {
    echo "Checking and installing firewalld..."
    dnf install -y firewalld
    systemctl enable firewalld
    systemctl start firewalld
}

random() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "Installing 3proxy..."
    dnf install -y gcc make curl bsdtar zip
    URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
    curl -sL $URL | bsdtar -xvf-
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.service /etc/systemd/system/3proxy.service
    sed -i 's|/etc/3proxy/3proxy.cfg|/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
    sed -i 's|/bin/3proxy|/usr/local/etc/3proxy/bin/3proxy|' /etc/systemd/system/3proxy.service
    systemctl daemon-reload
    cd ..
}

gen_3proxy_cfg() {
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
"proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_firewall_rules() {
    awk -F "/" '{print "firewall-cmd --permanent --add-port=" $4 "/tcp"}' ${WORKDATA}
}

gen_ip_assign() {
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA}
}

gen_proxy_file_for_user() {
    awk -F "/" '{print $3":"$4":"$1":"$2 }' ${WORKDATA} > proxy.txt
}

# Setup
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "How many proxies do you want to create?"
read COUNT

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
done > $WORKDATA

# Install and start 3proxy
check_firewall
install_3proxy
gen_3proxy_cfg > /usr/local/etc/3proxy/3proxy.cfg
chmod +x /usr/local/etc/3proxy/3proxy.cfg

gen_firewall_rules > firewall.sh
bash firewall.sh
firewall-cmd --reload

gen_ip_assign > assign_ipv6.sh
bash assign_ipv6.sh

gen_proxy_file_for_user

systemctl enable 3proxy
systemctl start 3proxy

echo "3proxy installed and running. Proxy list saved to proxy.txt"
