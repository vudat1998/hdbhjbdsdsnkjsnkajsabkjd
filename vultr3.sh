#!/bin/bash

# Updated for CentOS 9 Stream x64

set -e

# Check and install firewalld
check_firewalld() {
    echo "Checking and installing firewalld..."
    if ! command -v firewall-cmd &> /dev/null; then
        dnf install -y firewalld
        systemctl enable firewalld
        systemctl start firewalld
    else
        echo "firewalld is already installed."
    fi
}

# Generate random string
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Array for IPv6 generation
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

# Generate IPv6 address
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Install 3proxy
install_3proxy() {
    echo "Installing 3proxy..."
    dnf install -y gcc make curl libarchive zip
    URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
    curl -sL $URL | tar -xzf -
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/3proxy.service /etc/systemd/system/3proxy.service
    sed -i 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE=/usr/local/etc/3proxy/3proxy.cfg|' /etc/systemd/system/3proxy.service
    sed -i 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' /etc/systemd/system/3proxy.service
    sed -i 's/RestartSec=60s/RestartSec=0s/' /etc/systemd/system/3proxy.service
    chmod +x /usr/local/etc/3proxy/bin/3proxy
    cd ..
}

# Generate 3proxy configuration
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
"proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# Generate firewall rules for firewalld
gen_firewall() {
    awk -F "/" '{print "firewall-cmd --permanent --add-port=" $4 "/tcp"}' ${WORKDATA}
}

# Generate IPv6 interface configuration
gen_ifconfig() {
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev " INTERFACE}' ${WORKDATA}
}

# Generate proxy file for user
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA} > proxy.txt
}

# Main setup
echo "Installing required packages..."
dnf -y install gcc net-tools curl libarchive zip >/dev/null

check_firewalld
install_3proxy

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP = ${IP4}. External subnet for IPv6 = ${IP6}"

echo "How many proxies do you want to create? Example: 500"
read COUNT

FIRST_PORT=10000
LAST_PORT=$((FIRST_PORT + COUNT - 1))

# Detect network interface
INTERFACE=$(ip link show | grep -oP '(?<=: )[^:]+' | grep -v lo | head -n1)
if [ -z "$INTERFACE" ]; then
    echo "Error: No network interface found."
    exit 1
fi

# Generate proxy data
seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
done > $WORKDATA

# Generate and apply configurations
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
chmod 600 /usr/local/etc/3proxy/3proxy.cfg

gen_firewall > $WORKDIR/boot_firewall.sh
bash $WORKDIR/boot_firewall.sh
firewall-cmd --reload

gen_ifconfig > $WORKDIR/boot_ifconfig.sh
sed -i "s/INTERFACE/$INTERFACE/g" $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh

gen_proxy_file_for_user

ulimit -n 10048
systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

echo "3proxy installation complete. Proxy list saved to $WORKDIR/proxy.txt"
