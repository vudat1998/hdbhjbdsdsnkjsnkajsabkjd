# rotate.sh
#!/bin/bash
WORKDIR="/home/proxy-installer"
WORKDATA="$WORKDIR/data.txt"
PROXYCFG="/usr/local/etc/3proxy/3proxy.cfg"

# Xóa cấu hình cũ và dọn interface, iptables
echo "[*] Clearing old proxy configs..."
bash "$WORKDIR/boot_ifconfig_delete.sh"
bash "$WORKDIR/boot_iptables_delete.sh"
systemctl restart NetworkManager
pkill -9 3proxy 2>/dev/null

# Lấy lại IP
IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -d: -f1-4)

# Tính số cổng từ data.txt cũ (nếu có) hoặc giữ COUNT cũ
if [ -f "$WORKDATA" ]; then
    COUNT=$(wc -l < "$WORKDATA")
else
    echo "[$(date)] Không tìm thấy $WORKDATA, thoát."
    exit 1
fi

FIRST_PORT=$(awk -F/ 'NR==1 {print $4}' "$WORKDATA")
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))

# Sinh data mới
random_str() { tr </dev/urandom -dc A-Za-z0-9 | head -c5; }
array=( {0..9} a b c d e f )
gen64() {
    local ip6=$1
    for i in {1..4}; do
        seg="${array[RANDOM%16]}${array[RANDOM%16]}${array[RANDOM%16]}${array[RANDOM%16]}"
        ip6="$ip6:$seg"
    done
    echo "$ip6"
}

echo "[*] Generating $COUNT new proxies on ports $FIRST_PORT..$LAST_PORT"
seq "$FIRST_PORT" "$LAST_PORT" | while read -r p; do
    echo "usr$(random_str)/pass$(random_str)/$IP4/$p/$(gen64 $IP6_PREFIX)"
done > "$WORKDATA"

# Sinh lại các script boot
awk -F/ '{print "iptables -I INPUT -p tcp --dport "$4" -m state --state NEW -j ACCEPT"}' "$WORKDATA" > "$WORKDIR/boot_iptables.sh"
awk -F/ '{print "iptables -D INPUT -p tcp --dport "$4" -m state --state NEW -j ACCEPT"}' "$WORKDATA" > "$WORKDIR/boot_iptables_delete.sh"
awk -F/ '{print "ifconfig eth0 inet6 add "$5"/64"}' "$WORKDATA" > "$WORKDIR/boot_ifconfig.sh"
awk -F/ '{print "ifconfig eth0 inet6 del "$5"/64"}' "$WORKDATA" > "$WORKDIR/boot_ifconfig_delete.sh"
chmod +x "$WORKDIR"/boot_*.sh

# Sinh config 3proxy và restart
{
    echo "daemon"; echo "maxconn 1000"; echo "nscache 65536"; echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid 65535"; echo "setuid 65535"; echo "flush"; echo "auth strong"
    echo -n "users "; awk -F/ 'BEGIN{ORS=" "} {print $1":CL:"$2}' "$WORKDATA"; echo
    awk -F/ '{printf "auth strong\nallow %s\nproxy -6 -n -a -p%s -i%s -e%s\nflush\n", $1,$4,$3,$5}' "$WORKDATA"
} > "$PROXYCFG"

ulimit -n 10048
bash "$WORKDIR/boot_iptables.sh"
bash "$WORKDIR/boot_ifconfig.sh"
systemctl restart 3proxy

# Xuất proxy.txt
awk -F/ '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "$WORKDIR/proxy.txt"
echo "[*] Rotate Done. Mới proxy: $WORKDIR/proxy.txt"
