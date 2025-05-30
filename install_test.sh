# install.sh
#!/bin/bash
# Thư mục làm việc và file dữ liệu
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXYCFG="/usr/local/etc/3proxy/3proxy.cfg"

check_prerequisites() {
    echo "[*] Cài đặt các gói cần thiết..."
    yum -y install gcc net-tools bsdtar zip iptables-services >/dev/null

    # Kiểm tra và bật iptables
    if ! systemctl is-active --quiet iptables; then
        echo "[*] iptables chưa kích hoạt, đang enable & start..."
        systemctl enable iptables
        systemctl start iptables
    else
        echo "[*] iptables đã đang chạy."
    fi
}

install_or_reset_3proxy() {
    if command -v 3proxy &>/dev/null; then
        echo "[*] Phát hiện 3proxy đã cài. Xóa cấu hình cũ và restart service..."
        # Xóa config cũ, nhưng giữ binary và service file
        > "$PROXYCFG"
        systemctl restart 3proxy
    else
        echo "[*] Chưa cài 3proxy, tiến hành cài mới..."
        URL="https://raw.githubusercontent.com/vudat1998/hdbhjbdsdsnkjsnkajsabkjd/main/3proxy-3proxy-0.9.4.tar.gz"
        wget -qO- "$URL" | bsdtar -xvf- >/dev/null
        cd 3proxy-0.9.4
        make -f Makefile.Linux >/dev/null
        mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
        cp bin/3proxy /usr/local/etc/3proxy/bin/
        cp scripts/3proxy.service /etc/systemd/system/3proxy.service
        sed -i \
          -e 's|Environment=CONFIGFILE=/etc/3proxy/3proxy.cfg|Environment=CONFIGFILE='"$PROXYCFG"'|' \
          -e 's|ExecStart=/bin/3proxy ${CONFIGFILE}|ExecStart=/usr/local/etc/3proxy/bin/3proxy ${CONFIGFILE}|' \
          -e 's/RestartSec=60s/RestartSec=0s/' \
          /etc/systemd/system/3proxy.service
        chmod +x /usr/local/etc/3proxy/bin/3proxy
        systemctl daemon-reload
        systemctl enable 3proxy
        cd "$WORKDIR"
    fi
}

# Hàm sinh chuỗi ngẫu nhiên
random_str() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
}

# Mảng hex để sinh IPv6
array=( {0..9} a b c d e f )
gen64() {
    local ip6pref=$1
    local segment() {
        printf '%s%s%s%s' \
            "${array[RANDOM%16]}" "${array[RANDOM%16]}" \
            "${array[RANDOM%16]}" "${array[RANDOM%16]}"
    }
    echo "$ip6pref:$(segment):$(segment):$(segment):$(segment)"
}

# Tạo dữ liệu proxy
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
        echo "usr$(random_str)/pass$(random_str)/$IP4/$port/$(gen64 $IP6_PREFIX)"
    done
}

# Sinh file cấu hình 3proxy
gen_3proxy_cfg() {
    {
    cat <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users $(awk -F/ 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "$WORKDATA")
EOF
    awk -F/ '{ printf "auth strong\nallow %s\nproxy -6 -n -a -p%s -i%s -e%s\nflush\n", $1, $4, $3, $5 }' "$WORKDATA"
    } > "$PROXYCFG"
    chmod +x "$PROXYCFG"
}

# Sinh script iptables và ifconfig
gen_boot_scripts() {
    awk -F/ '{print "iptables -I INPUT -p tcp --dport "$4" -m state --state NEW -j ACCEPT"}' "$WORKDATA" > "$WORKDIR/boot_iptables.sh"
    awk -F/ '{print "iptables -D INPUT -p tcp --dport "$4" -m state --state NEW -j ACCEPT"}' "$WORKDATA" > "$WORKDIR/boot_iptables_delete.sh"
    awk -F/ '{print "ifconfig eth0 inet6 add "$5"/64"}' "$WORKDATA" > "$WORKDIR/boot_ifconfig.sh"
    awk -F/ '{print "ifconfig eth0 inet6 del "$5"/64"}' "$WORKDATA" > "$WORKDIR/boot_ifconfig_delete.sh"
    chmod +x "$WORKDIR"/boot_*.sh
}

# Main
echo "[*] Bắt đầu cài đặt..."
check_prerequisites
install_or_reset_3proxy

# Tạo workspace
mkdir -p "$WORKDIR" && cd "$WORKDIR"

IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -d: -f1-4)

echo "[*] IP4=$IP4, IP6 prefix=$IP6_PREFIX"
echo "[*] Nhập số proxy muốn tạo (ví dụ: 500):"
read -r COUNT

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))

gen_data > "$WORKDATA"
gen_boot_scripts
gen_3proxy_cfg

# Áp dụng ngay
bash "$WORKDIR/boot_iptables.sh"
bash "$WORKDIR/boot_ifconfig.sh"
ulimit -n 10048
systemctl restart 3proxy

# Xuất file cho user
awk -F/ '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "$WORKDIR/proxy.txt"
echo "Install Done"
