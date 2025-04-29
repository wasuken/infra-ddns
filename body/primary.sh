# 必要なパッケージのインストール
echo "必要なパッケージをインストールしています..."
sudo apt update
sudo apt install -y unbound nsd nsupdate dnsutils keepalived bind9-utils bind9

# root.hintsファイル取得
curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
sudo chown unbound: /var/lib/unbound/root.hints

# namedは勝手に有効/起動状態になるので停止
sudo systemctl disable named
sudo systemctl stop named

# DDNS認証キーの作成
echo "DDNS認証キーを作成しています..."
DDNS_KEY=$(tsig-keygen "${DDNS_KEYNAME}"|grep secret|awk '{print $2}'|sed 's/\"\|;//g')
echo "$DDNS_KEY"

# NSD設定ファイル作成
echo "NSD設定ファイルを作成しています..."
sudo cat > /etc/nsd/nsd.conf << EOF
server:
    hide-version: yes
    verbosity: 1
    database: "/var/lib/nsd/nsd.db"
    username: nsd
    zonesdir: "/etc/nsd/zones"

key:
    name: "${DDNS_KEYNAME}"
    algorithm: hmac-sha256
    secret: "${DDNS_KEY}"

zone:
    name: "${DOMAIN}"
    zonefile: "${DOMAIN}.zone"
    provide-xfr: ${SECONDARYIP} ${DDNS_KEYNAME}
    notify: ${SECONDARYIP} ${DDNS_KEYNAME}
    notify-retry: 5
EOF

# ゾーンファイル作成
echo "ゾーンファイルを作成しています..."
sudo mkdir -p /etc/nsd/zones
sudo cat > /etc/nsd/zones/${DOMAIN}.zone << EOF
\$TTL ${DNS_TTL}
@       IN      SOA     ns1.${DOMAIN}. admin.${DOMAIN}. (
                        $(date +%Y%m%d01)  ; Serial
                        3600            ; Refresh
                        1800            ; Retry
                        604800          ; Expire
                        ${DNS_TTL} )    ; Minimum TTL
; Name servers
@       IN      NS      ns1.${DOMAIN}.
@       IN      NS      ns2.${DOMAIN}.
; A records
@       IN      A       ${VIP}
ns1     IN      A       ${PRIMARYIP}
ns2     IN      A       ${SECONDARYIP}
dns     IN      A       ${VIP}
EOF

sudo chown -R nsd:nsd /etc/nsd/zones

# Unboundの設定（キャッシュDNS）
echo "Unbound設定ファイルを作成しています..."
sudo cat > /etc/unbound/unbound.conf << EOF
server:
    verbosity: 1
    interface: 0.0.0.0
    port: 5353
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 0.0.0.0/0 allow
    root-hints: "/var/lib/unbound/root.hints"
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    prefetch: yes
    num-threads: 2
    local-zone: "${DOMAIN}" transparent
    local-data: "${DOMAIN} 3600 IN NS ns1.${DOMAIN}."
    local-data: "${DOMAIN} 3600 IN NS ns2.${DOMAIN}."
    local-data: "ns1.${DOMAIN} 3600 IN A ${PRIMARYIP}"
    local-data: "ns2.${DOMAIN} 3600 IN A ${SECONDARYIP}"
    local-data: "dns.${DOMAIN} 3600 IN A ${VIP}"

forward-zone:
    name: "."
    forward-addr: 1.1.1.1   # Cloudflare DNS
    forward-addr: 8.8.8.8   # Google DNS
EOF

# ISC-DHCP-Serverの設定
echo "DHCPサーバ設定ファイルを作成しています..."
sudo cat > /etc/dhcp/dhcpd.conf << EOF
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
use-host-decl-names on;

key "${DDNS_KEYNAME}" {
    algorithm hmac-sha256;
    secret "${DDNS_KEY}";
};

zone ${DOMAIN}. {
    primary ${PRIMARYIP};
    key ${DDNS_KEYNAME};
}

subnet ${NETWORK} netmask ${NETMASK} {
    option routers 192.168.20.1;
    option domain-name "${DOMAIN}";
    option domain-name-servers ${VIP};
    range 192.168.20.100 192.168.20.200;
    default-lease-time 600;
    max-lease-time 7200;

    # クライアントのホスト名をDNSに登録
    ddns-hostname = binary-to-ascii(10, 8, "-", leased-address);
    ddns-domain-name = "${DOMAIN}";
}

# 静的IPアドレス設定例
# host static-device1 {
#     hardware ethernet 00:11:22:33:44:55;
#     fixed-address 192.168.1.50;
#     ddns-hostname "device1";
#     ddns-domain-name "${DOMAIN}";
# }
EOF

# DHCP用インターフェース設定
sudo sed -i 's/INTERFACESv4=""/INTERFACESv4="eth0"/' /etc/default/isc-dhcp-server

# keepalived設定（プライマリDNSサーバ）
echo "Keepalived設定ファイルを作成しています..."
sudo cat > /etc/keepalived/keepalived.conf << EOF
global_defs {
    router_id LVS_DEVEL
    script_user root
    enable_script_security
}

vrrp_script chk_dns {
    script "/usr/bin/killall -0 nsd"
    interval 2
    weight 2
}

vrrp_instance DNS_HA {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass secret123
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_dns
    }
}
EOF

# カーネルパラメータの設定（VRRPのマルチキャスト用）
grep -qxF  'net.ipv4.ip_nonlocal_bind = 1'  /etc/sysctl.conf || echo 'net.ipv4.ip_nonlocal_bind = 1' || sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# サービスの有効化と再起動
echo "サービスを有効化して再起動しています..."
sudo systemctl enable nsd
sudo systemctl restart nsd
sudo systemctl enable unbound
sudo systemctl restart unbound
sudo systemctl enable keepalived
sudo systemctl restart keepalived

echo "プライマリDNSサーバのセットアップが完了しました"
