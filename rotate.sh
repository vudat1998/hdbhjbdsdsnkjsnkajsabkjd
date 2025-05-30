#!/bin/sh
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
clear_proxy_and_file(){
	
    > /usr/local/etc/3proxy/3proxy.cfg
    > $WORKDIR/data.txt
    > $WORKDIR/proxy.txt
    chmod +x ${WORKDIR}/boot_ifconfig_delete.sh $WORKDIR/boot_iptables_delete.sh
    bash $WORKDIR/boot_ifconfig_delete.sh
    bash $WORKDIR/boot_iptables_delete.sh
    ps aux | grep '[3]proxy' | awk '{print $2}' | xargs kill -9
    systemctl restart NetworkManager
    > ${WORKDIR}/boot_iptables.sh
    > ${WORKDIR}/boot_ifconfig.sh
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
gen_proxy_file_for_user() {
    cat >$WORKDIR/proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

upload_proxy() {
    echo "Rotate Done"

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
clear_proxy_and_file

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. Exteranl sub for ip6 = ${IP6}"

echo "How many proxy do you want to create? Example 500"
read COUNT

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT))
echo "gen_data"
gen_data >$WORKDIR/data.txt
echo "gen_iptables"
gen_iptables >$WORKDIR/boot_iptables.sh
gen_iptables_delete > $WORKDIR/boot_iptables_delete.sh
echo "gen_ifconfig"
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
gen_ifconfig_delete >$WORKDIR/boot_ifconfig_delete.sh
chmod +x ${WORKDIR}/boot_*.sh /etc/rc.d/rc.local
echo "gen_3proxy"
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg
ulimit -n 10048
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
echo "gen_proxy_file_for_user"
gen_proxy_file_for_user
systemctl daemon-reload
systemctl restart 3proxy
echo "Rotate Done"
