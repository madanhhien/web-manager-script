
#!/bin/bash

# AUTO SCRIPT QUAN LY WEB SERVER
# He dieu hanh: CentOS 7 / he tuong thich RHEL 7 (BIND + Apache)
# Web Server: Apache HTTPD

if [ "$EUID" -ne 0 ]; then
    echo "Vui long chay chuong trinh bang root!"
    exit 1
fi

pause() {
    read -r -p "Nhan Enter de tiep tuc..."
}

check_apache() {
    if ! rpm -q httpd >/dev/null 2>&1; then
        echo "Apache chua duoc cai dat!"
        return 1
    fi
}


# Website do script quan ly duoc luu rieng de tranh xoa nham.
SITE_BASE=/var/www/webmanager-sites
CONF_BASE=/etc/httpd/conf.d
BACKUP_DIR=/root/web-backups
DNS_ZONE_DIR=/var/named/webmanager
DNS_INCLUDE=/etc/named.webmanager.zones
DNS_MARKER='# WEBMANAGER MANAGED ZONES'

ensure_dns_setup() {
    if ! rpm -q bind bind-utils >/dev/null 2>&1; then
        echo 'Can cai dat BIND va bind-utils: yum install -y bind bind-utils'
        return 1
    fi
    [[ -f /etc/named.conf ]] || { echo 'Khong tim thay /etc/named.conf'; return 1; }
    mkdir -p "$DNS_ZONE_DIR" || return 1
    chown root:named "$DNS_ZONE_DIR"
    chmod 750 "$DNS_ZONE_DIR"
    if [[ ! -f "$DNS_INCLUDE" ]]; then
        printf '%s\n' "$DNS_MARKER" > "$DNS_INCLUDE"
        chmod 644 "$DNS_INCLUDE"
    fi
    if ! grep -Fq 'include "/etc/named.webmanager.zones";' /etc/named.conf; then
        cp -p /etc/named.conf "/etc/named.conf.webmanager.$(date +%Y%m%d_%H%M%S).bak" || return 1
        printf '\ninclude "%s";\n' "$DNS_INCLUDE" >> /etc/named.conf
    fi
    # On new CentOS, named.conf often listens only on loopback.
    # For testing on the CentOS machine, localhost is enough.
    named-checkconf || return 1
    systemctl enable named >/dev/null 2>&1
    systemctl start named || { echo 'Khong the khoi dong named; kiem tra journalctl -u named'; return 1; }
}

server_ipv4() {
    local suggested answer
    suggested=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -n "$suggested" ]] || suggested=$(hostname -I | awk '{print $1}')
    read -r -p "Nhap IP Web Server [$suggested]: " answer
    SERVER_IP=${answer:-$suggested}
    if ! [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo 'IP khong hop le!'; return 1
    fi
    local i
    IFS=. read -r -a octets <<< "$SERVER_IP"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for i in "${octets[@]}"; do
        [[ "$i" =~ ^[0-9]{1,3}$ ]] && ((10#$i <= 255)) || { echo 'IP khong hop le!'; return 1; }
    done
}

# Each site gets its own local master zone. The script refuses to
# overwrite pre-existing zones or names managed by other software.
dns_create() {
    local domain="$1" ip="$2" zonefile="$DNS_ZONE_DIR/$domain.zone"
    if grep -Eiq "zone[[:space:]]+\"${domain//./\.}\"[[:space:]]" <(named-checkconf -p 2>/dev/null); then
        echo "DNS zone $domain da ton tai. Khong ghi de zone cu."
        return 1
    fi
    [[ ! -e "$zonefile" ]] || { echo 'DNS zone file da ton tai'; return 1; }
    cat > "$zonefile" <<EOF
\$TTL 300
@ IN SOA ns1.$domain. admin.$domain. (
    $(date +%Y%m%d)01 3600 900 604800 300 )
@   IN NS ns1.$domain.
ns1 IN A $ip
@   IN A $ip
www IN A $ip
EOF
    chown root:named "$zonefile"; chmod 640 "$zonefile"
    command -v restorecon >/dev/null && restorecon "$zonefile" >/dev/null 2>&1
    if ! named-checkzone "$domain" "$zonefile"; then rm -f "$zonefile"; return 1; fi
    printf '\nzone "%s" IN { type master; file "webmanager/%s.zone"; allow-update { none; }; };\n' "$domain" "$domain" >> "$DNS_INCLUDE"
    if ! named-checkconf || ! systemctl reload named; then
        sed -i "/^zone \"${domain//./\\.}\" IN /d" "$DNS_INCLUDE"
        rm -f "$zonefile"
        systemctl reload named >/dev/null 2>&1
        echo 'DNS loi, da hoan tac zone moi.'
        return 1
    fi
}

dns_delete() {
    local domain="$1" zonefile="$DNS_ZONE_DIR/$domain.zone"
    [[ -f "$zonefile" ]] || return 0
    [[ -f "$DNS_INCLUDE" ]] || { echo 'Khong tim thay DNS include file'; return 1; }
    local temp
    temp=$(mktemp -d /root/webmanager-dns.XXXXXX) || return 1
    cp -p "$zonefile" "$temp/"; cp -p "$DNS_INCLUDE" "$temp/include"
    sed -i "/^zone \"${domain//./\\.}\" IN /d" "$DNS_INCLUDE"
    mv "$zonefile" "$temp/zone" || return 1
    if ! named-checkconf || ! systemctl reload named; then
        cp -p "$temp/include" "$DNS_INCLUDE"
        mv "$temp/zone" "$zonefile"
        systemctl reload named >/dev/null 2>&1
        echo 'Khong the xoa zone DNS; da hoan tac.'
        rm -rf "$temp"; return 1
    fi
    rm -rf "$temp"
}


valid_domain() {
    local d="$1"
    [[ ${#d} -le 253 && "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Website phai o thu muc rieng, khong duoc la symlink hay thu muc he thong.
# Chap nhan thu muc website tuy chon (vd /srv/websites, /home/demo/websites).
# Path do script tao luon ket thuc bang /<domain>.
valid_site_path() {
    local path="$1" domain="$2" ancestor
    valid_domain "$domain" || return 1
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
    [[ "$(basename -- "$path")" == "$domain" ]] || return 1
    [[ "$(realpath -m -- "$path")" == "$path" ]] || return 1
    case "$path" in
        /|/etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/dev/*|/proc/*|/sys/*|/run/*|/root/*|/var/log/*|/var/lib/*|/var/run/*|/var/cache/*|/tmp/*|/var/tmp/*) return 1 ;;
    esac
    ancestor="$path"
    while [[ "$ancestor" != / ]]; do
        [[ ! -L "$ancestor" ]] || return 1
        ancestor=$(dirname -- "$ancestor")
    done
}

# Doc DocumentRoot cua file Virtual Host do WebManager quan ly.
managed_site_path() {
    local domain="$1" conf="$CONF_BASE/webmanager-$1.conf" p
    [[ -f "$conf" && ! -L "$conf" ]] || return 1
    p=$(sed -nE 's/^[[:space:]]*DocumentRoot "([^"]+)"[[:space:]]*$/\1/p' "$conf" | head -n 1)
    valid_site_path "$p" "$domain" || return 1
    printf '%s\n' "$p"
}

apply_apache() {
    if ! apachectl configtest; then
        echo 'Cau hinh Apache khong hop le!'
        return 1
    fi
    if systemctl is-active --quiet httpd; then
        systemctl reload httpd
    else
        systemctl start httpd
    fi
}

create_site() {
    echo '===== TAO WEBSITE MOI (APACHE + DNS) ====='
    check_apache || return 1
    local domain path parent conf choice answer
    read -r -p 'Nhap domain (vd: shop.test): ' domain
    domain="${domain,,}"
    valid_domain "$domain" || { echo 'Domain khong hop le!'; return 1; }
    read -r -p "Nhap thu muc website [$SITE_BASE]: " parent
    parent=${parent:-$SITE_BASE}
    [[ "$parent" == /* && "$parent" != *$'\n'* && "$parent" != *$'\t'* ]] || {
        echo 'Thu muc website  phai la duong dan tuyet doi!'; return 1;
    }
    parent=$(realpath -m -- "$parent") || return 1
    path="$parent/$domain"
    valid_site_path "$path" "$domain" || {
        echo 'Duong dan khong an toan (symlink/thu muc he thong)!'; return 1;
    }
    conf="$CONF_BASE/webmanager-$domain.conf"
    if [[ -e "$conf" || -e "$path" ]]; then echo 'Website da ton tai!'; return 1; fi
    server_ipv4 || return 1
    echo '========== XAC NHAN =========='
    echo "Domain: $domain"
    echo "Thu muc website chinh: $parent"
    echo "Thu muc website: $path"
    echo "Web Server IP: $SERVER_IP"
    echo '1. Xac nhan tao website'
    echo '0. Huy'
    read -r -p 'Nhap lua chon: ' choice
    [[ "$choice" == 1 ]] || { echo 'Da huy tao website.'; return 0; }
    ensure_dns_setup || return 1
    if grep -Eiq "zone[[:space:]]+\"${domain//./\.}\"[[:space:]]" <(named-checkconf -p 2>/dev/null); then
        echo 'Zone DNS da ton tai; khong ghi de. Chon domain moi.'; return 1
    fi
    # Chi tao thu muc khi cha khong co symlink va khong ghi de du lieu.
    mkdir -p -- "$parent" || return 1
    valid_site_path "$path" "$domain" || return 1
    mkdir -- "$path" || return 1
    cat > "$path/index.html" <<EOF
<!DOCTYPE html><html lang="vi"><head><meta charset="UTF-8"><title>$domain</title>
<style>body{font-family:Arial;text-align:center;background:#eef3ff;padding:70px}main{background:white;max-width:680px;margin:auto;padding:35px;border-radius:12px}h1{color:#1558a6}</style></head>
<body><main><h1>WEBSITE: $domain</h1><h2>Web Server Management - CentOS 7</h2><p>Website da duoc tao tu dong bang Bash Script!</p></main></body></html>
EOF
    chmod 755 "$path"; chmod 644 "$path/index.html"
    cat > "$conf" <<EOF
<VirtualHost *:80>
    ServerName $domain
    DocumentRoot "$path"
    <Directory "$path">
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF
    # SELinux: gan nhan website, dac biet khi luu ngoai /var/www.
    if command -v chcon >/dev/null 2>&1; then
        chcon -R -t httpd_sys_content_t -- "$path" 2>/dev/null || true
    fi
    if ! apply_apache; then
        rm -f "$conf" "$path/index.html"; rmdir "$path" 2>/dev/null
        echo 'Apache loi. Da hoan tac.'; return 1
    fi
    if ! dns_create "$domain" "$SERVER_IP"; then
        rm -f "$conf" "$path/index.html"; rmdir "$path" 2>/dev/null
        apply_apache >/dev/null 2>&1
        echo 'DNS loi. Da hoan tac website.'; return 1
    fi
    echo "[OK] Website: http://$domain"
    echo "[OK] IP: $SERVER_IP"
    echo "Thu: dig @127.0.0.1 $domain +short"
    echo "Thu: curl -H 'Host: $domain' http://127.0.0.1/"
    echo 'Luu y: May client can dung DNS BIND nay; IP DHCP co the thay doi.'
}

delete_site() {
    echo '===== XOA WEBSITE ====='
    local domain conf path answer
    read -r -p 'Nhap domain can xoa: ' domain
    domain="${domain,,}"
    if ! valid_domain "$domain"; then echo 'Domain khong hop le!'; return 1; fi
    conf="$CONF_BASE/webmanager-$domain.conf"
    if [[ ! -f "$conf" || -L "$conf" ]]; then
        echo 'Website khong do script quan ly hoac khong ton tai.'
        return 1
    fi
    path=$(managed_site_path "$domain") || {
        echo 'Khong xac minh duoc DocumentRoot an toan.'; return 1;
    }
    if [[ ! -d "$path" ]]; then
        echo 'Duong dan website khong an toan. Huy xoa.'
        return 1
    fi
    echo "Se xoa: $domain"
    echo "Thu muc website: $path"
    echo "Cau hinh: $conf"
    echo 'Nen chon 7 de sao luu TRUOC khi xoa.'
    read -r -p "Nhap YES de xac nhan xoa: " answer
    if [[ "$answer" != 'YES' ]]; then echo 'Da huy xoa.'; return 0; fi
    local tmpdir
    tmpdir=$(mktemp -d /root/webmanager-delete.XXXXXX) || return 1
    mv -- "$conf" "$tmpdir/" || { rmdir "$tmpdir"; return 1; }
    if ! apply_apache; then
        mv -- "$tmpdir/$(basename "$conf")" "$conf"
        rmdir "$tmpdir"
        echo 'Khong the ap dung cau hinh, giu nguyen du lieu.'
        return 1
    fi
    if ! dns_delete "$domain"; then
        mv -- "$tmpdir/$(basename "$conf")" "$conf"
        apply_apache >/dev/null 2>&1
        echo 'Huy xoa website do DNS gap loi.'
        return 1
    fi
    # Chi xoa website cua script, khong xoa thu muc khac.
    if rm -rf --one-file-system -- "$path"; then
        echo "Da xoa website: $domain"
    else
        echo 'Xoa du lieu that bai. Can kiem tra lai.'
    fi
    rm -rf -- "$tmpdir"
}

# Lay danh sach duong dan site do script quan ly tu Virtual Host.
# Khong bao gio backup toan bo thu muc website tuy chon.
managed_paths() {
    local f d p
    for f in "$CONF_BASE"/webmanager-*.conf; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        d=${f##*/webmanager-}
        d=${d%.conf}
        p=$(managed_site_path "$d") || {
            echo "Bo qua config khong an toan: $f" >&2
            return 1
        }
        [[ -d "$p" && ! -L "$p" ]] || { echo "Thieu website $d" >&2; return 1; }
        printf '%s\n' "$p"
    done
}

backup_sites() {
    echo '===== SAO LUU WEBSITE ====='
    mkdir -p "$BACKUP_DIR" || return 1
    local outfile f p
    local -a items=()
    outfile="$BACKUP_DIR/website_$(date +%Y%m%d_%H%M%S).tar.gz"
    [[ -d "$SITE_BASE" ]] && items+=("${SITE_BASE#/}")
    [[ -d /var/www/html ]] && items+=(var/www/html)
    [[ -f "$DNS_INCLUDE" ]] && items+=(etc/named.webmanager.zones)
    [[ -d "$DNS_ZONE_DIR" ]] && items+=(var/named/webmanager)
    for f in "$CONF_BASE"/webmanager-*.conf; do
        [[ -f "$f" && ! -L "$f" ]] && items+=("${f#/}")
    done
    local paths
    paths=$(managed_paths) || { echo 'Khong backup vi website khong an toan.'; return 1; }
    while IFS= read -r p; do
        [[ -n "$p" && "$p" != "$SITE_BASE/"* ]] && items+=("${p#/}")
    done <<< "$paths"
    if (( ${#items[@]} == 0 )); then echo 'Khong co du lieu de sao luu'; return 1; fi
    if tar -czf "$outfile" -C / "${items[@]}"; then
        echo "Sao luu thanh cong: $outfile"
    else
        rm -f -- "$outfile"
        echo 'Sao luu that bai!'; return 1
    fi
}

restore_sites() {
    echo '===== KHOI PHUC WEBSITE ====='
    [[ -d "$BACKUP_DIR" ]] || { echo 'Chua co thu muc backup!'; return 1; }
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'website_*.tar.gz' -print
    local name file confirm entry f domain p first config_data
    read -r -p 'Nhap ten file backup: ' name
    [[ "$name" =~ ^website_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]] || { echo 'Ten file backup khong hop le!'; return 1; }
    file="$BACKUP_DIR/$name"
    [[ -f "$file" && ! -L "$file" ]] || { echo 'Khong tim thay file backup!'; return 1; }
    tar -tzf "$file" >/dev/null || { echo 'Backup bi loi!'; return 1; }
    # Lay duong dan site TU FILE CONFIG TRONG BACKUP, khong tin vao config hien tai.
    local -a allowed=()
    while IFS= read -r f; do
        [[ "$f" == etc/httpd/conf.d/webmanager-*.conf ]] || continue
        domain=${f##*/webmanager-}; domain=${domain%.conf}
        valid_domain "$domain" || { echo 'Domain trong backup khong hop le'; return 1; }
        config_data=$(tar -xOzf "$file" -- "$f") || return 1
        p=$(printf '%s\n' "$config_data" | sed -nE 's/^[[:space:]]*DocumentRoot "([^"]+)"[[:space:]]*$/\1/p' | head -n 1)
        valid_site_path "$p" "$domain" || { echo "DocumentRoot khong an toan: $p"; return 1; }
        allowed+=("${p#/}")
    done < <(tar -tzf "$file")
    # Chi chap nhan cac tep he thong cu va site khop voi config do script tao.
    local ok ap
    while IFS= read -r entry; do
        entry=${entry%/}
        [[ "$entry" != /* && "$entry" != *'../'* && "$entry" != *'/..' && "$entry" != *'/./'* ]] || {
            echo "Duong dan trong backup nguy hiem: $entry"; return 1;
        }
        ok=0
        case "$entry" in
            var/www/html|var/www/html/*|html|html/*|var/www/webmanager-sites|var/www/webmanager-sites/*|etc/httpd/conf.d/webmanager-*.conf|var/named/webmanager|var/named/webmanager/*|etc/named.webmanager.zones) ok=1 ;;
        esac
        for ap in "${allowed[@]}"; do
            [[ "$entry" == "$ap" || "$entry" == "$ap/"* ]] && ok=1
            # tar co the luu cac thu muc website.
            [[ "$ap" == "$entry/"* ]] && ok=1
        done
        (( ok == 1 )) || { echo "Backup co tep ngoai danh sach: $entry"; return 1; }
    done < <(tar -tzf "$file")
    if tar -tvzf "$file" | grep -Eq '^[lh]'; then
        echo 'Backup co symbolic/hard link; huy khoi phuc.'; return 1
    fi
    echo 'Luu y: khoi phuc ghi de tep trung ten; khong xoa website khac.'
    read -r -p 'Xac nhan khoi phuc (yes/no): ' confirm
    [[ "$confirm" == yes ]] || { echo 'Da huy khoi phuc.'; return 0; }
    first=$(tar -tzf "$file" | head -n 1)
    if [[ "$first" == html || "$first" == html/* ]]; then
        mkdir -p /var/www
        tar -xzf "$file" -C /var/www || return 1
    else
        tar -xzf "$file" -C / || return 1
    fi
    # Restore SELinux cho /var/www; chcon cho cac site ngoai thu muc mac dinh.
    command -v restorecon >/dev/null 2>&1 && restorecon -R /var/www/html "$SITE_BASE" >/dev/null 2>&1
    for ap in "${allowed[@]}"; do
        p="/$ap"
        if [[ -d "$p" ]] && command -v chcon >/dev/null 2>&1; then
            chcon -R -t httpd_sys_content_t -- "$p" 2>/dev/null || true
        fi
    done
    if [[ -f "$DNS_INCLUDE" ]]; then
        ensure_dns_setup || { echo 'Khong the khoi phuc DNS.'; return 1; }
        chown -R root:named "$DNS_ZONE_DIR" 2>/dev/null
        named-checkconf -z || { echo 'DNS khong hop le!'; return 1; }
        systemctl reload named || return 1
    fi
    if apply_apache; then
        echo 'Khoi phuc website thanh cong!'
    else
        echo 'Da giai nen nhung Apache chua nap duoc cau hinh.'; return 1
    fi
}

while true
do
    clear
    echo "======================================"
    echo "      WEB SERVER MANAGEMENT"
    echo "          CENTOS 7"
    echo "======================================"
    echo "1. Cai dat Apache"
    echo "2. Khoi dong Apache"
    echo "3. Dung Apache"
    echo "4. Khoi dong lai Apache"
    echo "5. Kiem tra trang thai Apache"
    echo "6. Tao Website Moi"
    echo "7. Sao luu Website"
    echo "8. Khoi phuc Website"
    echo "9. Xem nhat ky Apache"
    echo "10. Xoa Website"
    echo "0. Thoat"
    echo "======================================"
    read -r -p "Nhap lua chon cua ban: " choice
    case "$choice" in
        1)
            echo "Dang cai dat Apache..."
            if yum install -y httpd; then
                systemctl enable httpd
                systemctl start httpd
                echo "Da cai dat va khoi dong Apache."
            else
                echo "Cai dat that bai!"
            fi
            pause
            ;;
        2)
            if check_apache; then
                systemctl start httpd
                systemctl is-active httpd
            fi
            pause
            ;;
        3)
            if check_apache; then
                systemctl stop httpd
                systemctl is-active httpd
            fi
            pause
            ;;
        4)
            if check_apache; then
                if apachectl configtest; then
                    systemctl restart httpd
                    systemctl is-active httpd
                else
                    echo "Cau hinh Apache bi loi!"
                fi
            fi
            pause
            ;;
        5)
            if check_apache; then
                systemctl status httpd --no-pager
            fi
            pause
            ;;
        
        6)
            create_site
            pause
            ;;
        7)
            backup_sites
            pause
            ;;
        8)
            restore_sites
            pause
            ;;
        9)
            echo "================================"
            echo "       NHAT KY APACHE"
            echo "================================"
            echo "1. Xem nhat ky truy cap"
            echo "2. Xem nhat ky loi"
            echo "3. Xem 20 dong log moi nhat"
            echo "================================"

            read -r -p "Nhap lua chon: " log_choice

            case "$log_choice" in
                1)
                    if [ -f /var/log/httpd/access_log ]; then
                        less /var/log/httpd/access_log
                    else
                        echo "Chua co access log!"
                    fi
                    ;;
                2)
                    if [ -f /var/log/httpd/error_log ]; then
                        less /var/log/httpd/error_log
                    else
                        echo "Chua co error log!"
                    fi
                    ;;
                3)
                    if [ -f /var/log/httpd/access_log ]; then
                        tail -n 20 /var/log/httpd/access_log
                    else
                        echo "Chua co access log!"
                    fi
                    ;;
                *)
                    echo "Lua chon khong hop le!"
                    ;;
            esac

            pause
            ;;

        10)
            delete_site
            pause
            ;;
        0)
            echo "Thoat chuong trinh!"
            exit 0
            ;;
        *)
            echo "Lua chon khong hop le!"
            pause
            ;;
    esac
done
