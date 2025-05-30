#!/bin/sh
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
random() {
	tr </dev/urandom -dc A-Za-z0-9 | head -c5
	echo
}
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
	ip64() {
		echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
	}
	echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}
install_vinmmoproxy() {
    echo "installing vinmmoproxy"
    URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/vinmmoproxy-vinmmoproxy-0.9.4.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd vinmmoproxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/vinmmoproxy/{bin,logs,stat}
    cp bin/vinmmoproxy /usr/local/etc/vinmmoproxy/bin/
    cp scripts/vinmmoproxy.service /etc/systemd/system/vinmmoproxy.service
    sed -i 's|Environment=CONFIGFILE=/etc/vinmmoproxy/vinmmoproxy.cfg|Environment=CONFIGFILE=/usr/local/etc/vinmmoproxy/vinmmoproxy.cfg|' /etc/systemd/system/vinmmoproxy.service
    sed -i 's|ExecStart=/bin/vinmmoproxy ${CONFIGFILE}|ExecStart=/usr/local/etc/vinmmoproxy/bin/vinmmoproxy ${CONFIGFILE}|' /etc/systemd/system/vinmmoproxy.service
    sed -i 's/RestartSec=60s/RestartSec=0s/' /etc/systemd/system/vinmmoproxy.service
    chmod +x /usr/local/etc/vinmmoproxy/bin/vinmmoproxy
    cd $WORKDIR
}


gen_vinmmoproxy() {
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

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

upload_proxy() {
    echo "upload"

}
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "usr$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    cat <<EOF
    $(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}
gen_iptables_delete() {
    cat <<EOF
    $(awk -F "/" '{print "iptables -D INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}


gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}
gen_ifconfig_delete() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64"}' ${WORKDATA})
EOF
}
echo "installing apps"
yum -y install gcc net-tools bsdtar zip >/dev/null
check_iptables_install
install_vinmmoproxy

echo "working folder = /home/proxy-installer"
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir $WORKDIR && cd $_

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. Exteranl sub for ip6 = ${IP6}"

echo "How many proxy do you want to create? Example 500"
read COUNT

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT))

gen_data >$WORKDIR/data.txt
gen_iptables_delete > $WORKDIR/boot_iptables_delete.sh
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig_delete >$WORKDIR/boot_ifconfig_delete.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x ${WORKDIR}/boot_*.sh

gen_vinmmoproxy >/usr/local/etc/vinmmoproxy/vinmmoproxy.cfg
chmod +x /usr/local/etc/vinmmoproxy/vinmmoproxy.cfg
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
gen_proxy_file_for_user
systemctl daemon-reload
systemctl start vinmmoproxy
echo "Install Done"
