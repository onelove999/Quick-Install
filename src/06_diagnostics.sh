#!/usr/bin/env bash
# 06_diagnostics.sh — модуль комплексной диагностики сети и железа ноды для Quick-Install.
# Компактный дашборд: прогресс-бар → сводка → вердикт → рекомендации меню Quick-Install.
# Детальный лог пишется во временный файл при запуске (показывается в интерфейсе).
# Запуск:
#   Вызывается через главное меню Quick-Install -> Тесты и Бенчмарки -> Комплексная диагностика

# Globals moved to do_run_diagnostics to avoid namespace pollution

# Temp files will be created in do_run_diagnostics

# ────────────────────────────────────────────────────────────────────
# Хелперы
# ────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

cleanup_diagnostics() {
    if [ -n "${DIAG_ACTIVE_PID:-}" ]; then
        kill "$DIAG_ACTIVE_PID" 2>/dev/null || true
        wait "$DIAG_ACTIVE_PID" 2>/dev/null || true
    fi
    [ -n "${RES_FILE:-}" ] && rm -f "$RES_FILE"
    [ -n "${FINDINGS_FILE:-}" ] && rm -f "$FINDINGS_FILE"
    [ -n "${SUMMARY_FILE:-}" ] && rm -f "$SUMMARY_FILE"
}

interrupted_diagnostics() {
    DIAGNOSTICS_INTERRUPTED=1
    [ -n "${DIAG_ACTIVE_PID:-}" ] && kill "$DIAG_ACTIVE_PID" 2>/dev/null || true
}

# severity: 1=info(↓), 2=warn, 3=bad(↑)
finding() {
    echo "$1|$2|$3" >> "$FINDINGS_FILE"
}

summary_kv() {
    echo "$1|$2" >> "$SUMMARY_FILE"
}

CURL_FLAGS=(--connect-timeout 5 --retry 0 -4)

# Финальная строка проверки (после завершения)
print_line() {
    local i=$1 total=$2 icon=$3 name=$4 tail=$5
    local pct=$(( i * 100 / total ))
    printf "\r${CLR_LINE}${DIM}[%2d/%2d %3d%%]${NC} %b %-26s ${DIM}%s${NC}\n" \
        "$i" "$total" "$pct" "$icon" "$name" "$tail"
}

# Прогресс «в работе» — Braille-спиннер, 10 кадров, обновляется ~10 раз/с.
# Показываем общий % и ETA по среднему времени уже завершённых проверок.
print_progress() {
    local i=$1 total=$2 name=$3 frame=${4:-0} elapsed=${5:-0}
    local spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local spin=${spin_frames[$(( frame % 10 ))]}
    local pct=$(( (i - 1) * 100 / total ))
    local eta_str=""
    if [ "${ETA_AVG:-0}" -gt 0 ] && [ "${i}" -gt 1 ]; then
        local remaining=$(( (total - i + 1) * ETA_AVG ))
        if [ "$remaining" -gt 60 ]; then
            eta_str=" · ETA $(( remaining / 60 ))m $(( remaining % 60 ))s"
        elif [ "$remaining" -gt 0 ]; then
            eta_str=" · ETA ${remaining}s"
        fi
    fi
    if [ "$elapsed" -ge 1 ]; then
        printf "\r${CLR_LINE}${DIM}[%2d/%2d %3d%%]${NC} ${C}%s${NC} %-26s ${DIM}%ds%s${NC}" \
            "$i" "$total" "$pct" "$spin" "$name" "$elapsed" "$eta_str"
    else
        printf "\r${CLR_LINE}${DIM}[%2d/%2d %3d%%]${NC} ${C}%s${NC} %-26s${DIM}%s${NC}" \
            "$i" "$total" "$pct" "$spin" "$name" "$eta_str"
    fi
}

# Иконка по статусу
icon_for() {
    case "$1" in
        ok)   echo "${G}✓${NC}" ;;
        warn) echo "${Y}⚠${NC}" ;;
        bad)  echo "${R}✗${NC}" ;;
        skip) echo "${DIM}·${NC}" ;;
        *)    echo "?" ;;
    esac
}

# Запускает функцию проверки в фоне, рисует плавный прогресс, печатает результат.
# ETA считаем как (total - done) * average_time_per_check.
declare -i CHECK_NUM=0
declare -i CHECK_TOTAL_TIME=0
declare -i CHECK_DONE=0
declare -i ETA_AVG=0
declare -i DIAG_OK=0
declare -i DIAG_WARN=0
declare -i DIAG_BAD=0
declare -i DIAG_SKIP=0
CHECK_TOTAL=0

run_check() {
    local name=$1 fn=$2
    [ "${DIAGNOSTICS_INTERRUPTED:-0}" -eq 1 ] && return 130
    CHECK_NUM=$(( CHECK_NUM + 1 ))

    {
        echo
        echo "════════════════════════════════════════════════════════════════"
        echo "[$CHECK_NUM/$CHECK_TOTAL] $name"
        echo "════════════════════════════════════════════════════════════════"
    } >> "$LOG"

    : > "$RES_FILE"
    (
        RES_STATUS=ok
        RES_SUMMARY=""
        exec >> "$LOG" 2>&1
        local check_rc=0
        "$fn" || check_rc=$?
        if [ "$check_rc" -ne 0 ] && [ -z "$RES_SUMMARY" ]; then
            RES_STATUS=bad
            RES_SUMMARY="внутренняя ошибка (код $check_rc)"
            finding 3 internal "Проверка '$name' завершилась с кодом $check_rc без результата"
        fi
        printf '%s\n%s\n' "$RES_STATUS" "$RES_SUMMARY" > "$RES_FILE"
    ) &
    local pid=$!
    DIAG_ACTIVE_PID=$pid

    local start frame=0
    start=$(date +%s)
    # Polling каждые ~100ms — спиннер выглядит живым, не дёрганым
    while kill -0 "$pid" 2>/dev/null && [ "${DIAGNOSTICS_INTERRUPTED:-0}" -eq 0 ]; do
        local el=$(( $(date +%s) - start ))
        print_progress "$CHECK_NUM" "$CHECK_TOTAL" "$name" "$frame" "$el"
        sleep 0.1
        frame=$(( frame + 1 ))
    done
    [ "${DIAGNOSTICS_INTERRUPTED:-0}" -eq 1 ] && kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    DIAG_ACTIVE_PID=""

    if [ "${DIAGNOSTICS_INTERRUPTED:-0}" -eq 1 ]; then
        return 130
    fi

    local dur=$(( $(date +%s) - start ))
    CHECK_TOTAL_TIME=$(( CHECK_TOTAL_TIME + dur ))
    CHECK_DONE=$(( CHECK_DONE + 1 ))
    [ "$CHECK_DONE" -gt 0 ] && ETA_AVG=$(( CHECK_TOTAL_TIME / CHECK_DONE ))

    local st="bad" su="(нет результата)"
    if [ -s "$RES_FILE" ]; then
        st=$(sed -n '1p' "$RES_FILE")
        su=$(sed -n '2p' "$RES_FILE")
        [ -z "$st" ] && st="ok"
    fi
    case "$st" in
        ok) DIAG_OK=$((DIAG_OK + 1)) ;;
        warn) DIAG_WARN=$((DIAG_WARN + 1)) ;;
        bad) DIAG_BAD=$((DIAG_BAD + 1)) ;;
        skip|*) DIAG_SKIP=$((DIAG_SKIP + 1)) ;;
    esac
    print_line "$CHECK_NUM" "$CHECK_TOTAL" "$(icon_for "$st")" "$name" "$su"
}

# ────────────────────────────────────────────────────────────────────
# Установка зависимостей (тихо)
# ────────────────────────────────────────────────────────────────────
ensure_deps() {
    declare -A PKG_MAP=(
        [mpstat]="sysstat:sysstat:sysstat"
        [mtr]="mtr-tiny:mtr:mtr"
        [traceroute]="traceroute:traceroute:traceroute"
        [dig]="dnsutils:bind-utils:bind-tools"
        [nc]="netcat-openbsd:nmap-ncat:netcat-openbsd"
        [curl]="curl:curl:curl"
        [bc]="bc:bc:bc"
        [ethtool]="ethtool:ethtool:ethtool"
        [conntrack]="conntrack:conntrack-tools:conntrack-tools"
        [jq]="jq:jq:jq"
    )
    local PKG_INSTALL="" IDX=0
    if   have apt-get; then PKG_INSTALL="apt-get install -y -qq"; IDX=0
                            apt-get update -qq >/dev/null 2>&1 || true
    elif have dnf;     then PKG_INSTALL="dnf install -y -q";      IDX=1
    elif have yum;     then PKG_INSTALL="yum install -y -q";      IDX=1
    elif have apk;     then PKG_INSTALL="apk add --quiet";        IDX=2
                            apk update -q >/dev/null 2>&1 || true
    fi
    [ -z "$PKG_INSTALL" ] && return
    [ "$EUID" -ne 0 ] && return

    declare -A NEED=()
    for cmd in "${!PKG_MAP[@]}"; do
        if ! have "$cmd"; then
            IFS=':' read -ra pkgs <<< "${PKG_MAP[$cmd]}"
            NEED[${pkgs[$IDX]}]=1
        fi
    done
    [ ${#NEED[@]} -eq 0 ] && return
    # shellcheck disable=SC2086
    $PKG_INSTALL ${!NEED[*]} >/dev/null 2>&1 || true
}

# ════════════════════════════════════════════════════════════════════
# ПРОВЕРКИ — каждая выставляет RES_STATUS и RES_SUMMARY
# ════════════════════════════════════════════════════════════════════

# 1. Идентификация
check_identify() {
    local h ip4 ip6 kern distro virt up
    h=$(hostname)
    ip4=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 https://api.ipify.org || echo "")
    ip6=$(curl --connect-timeout 5 -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")

    # Кросс-чек гео из 3 независимых источников (ipinfo / ip-api / ipwho)
    # Хостинг-IP часто в одной базе показаны как FI, в другой как EE — фактический ДЦ
    # надёжнее определить через latency, не WHOIS.
    local ipinfo_country="?" ipinfo_city="?" ipinfo_org="?"
    local ipapi_country="?"  ipapi_city="?"  ipapi_org="?"
    local ipwho_country="?"  ipwho_city="?"  ipwho_org="?"

    if [ -n "$ip4" ]; then
        if have jq; then
            local g1 g2 g3
            g1=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 "https://ipinfo.io/$ip4/json" 2>/dev/null)
            g2=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 "http://ip-api.com/json/$ip4?fields=country,countryCode,city,isp,as" 2>/dev/null)
            g3=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 "https://ipwho.is/$ip4" 2>/dev/null)
            ipinfo_country=$(echo "$g1" | jq -r '.country // "?"')
            ipinfo_city=$(echo    "$g1" | jq -r '.city // "?"')
            ipinfo_org=$(echo     "$g1" | jq -r '.org // "?"')
            ipapi_country=$(echo  "$g2" | jq -r '.countryCode // "?"')
            ipapi_city=$(echo     "$g2" | jq -r '.city // "?"')
            ipapi_org=$(echo      "$g2" | jq -r '.isp // .as // "?"')
            ipwho_country=$(echo  "$g3" | jq -r '.country_code // "?"')
            ipwho_city=$(echo     "$g3" | jq -r '.city // "?"')
            ipwho_org=$(echo      "$g3" | jq -r '.connection.isp // .connection.org // "?"')
        else
            ipinfo_city=$(curl    "${CURL_FLAGS[@]}" -s --max-time 5 https://ipinfo.io/city)
            ipinfo_country=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 https://ipinfo.io/country)
            ipinfo_org=$(curl     "${CURL_FLAGS[@]}" -s --max-time 5 https://ipinfo.io/org)
        fi
    fi

    # Latency-проба к местным IX'ам — самая надёжная оценка реального положения ДЦ
    # (TLD выбран по ipinfo, не доверяем — пробуем оба ближайших)
    local lat_helsinki lat_tallinn lat_stockholm lat_riga lat_warsaw
    lat_helsinki=$(ping -c 3 -W 1 -q nordu.net 2>/dev/null     | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_tallinn=$(ping  -c 3 -W 1 -q estpak.ee 2>/dev/null     | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_stockholm=$(ping -c 3 -W 1 -q sunet.se 2>/dev/null     | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_riga=$(ping     -c 3 -W 1 -q lattelecom.lv 2>/dev/null | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_warsaw=$(ping   -c 3 -W 1 -q nask.pl 2>/dev/null       | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')

    kern=$(uname -sr)
    distro=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)
    virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
    up=$(uptime -p 2>/dev/null || echo "?")

    echo "Hostname: $h"
    echo "IPv4:     $ip4"
    echo "IPv6:     ${ip6:-нет}"
    echo
    echo "--- Geo cross-check (база | страна | город | ISP) ---"
    printf "  ipinfo.io:   %-3s %s · %s\n"   "$ipinfo_country" "$ipinfo_city" "$ipinfo_org"
    printf "  ip-api.com:  %-3s %s · %s\n"   "$ipapi_country"  "$ipapi_city"  "$ipapi_org"
    printf "  ipwho.is:    %-3s %s · %s\n"   "$ipwho_country"  "$ipwho_city"  "$ipwho_org"
    echo
    echo "--- Latency до национальных эндпоинтов (показывает реальную локацию ДЦ) ---"
    printf "  Helsinki  (nordu.net):     %s ms\n" "${lat_helsinki:-нет}"
    printf "  Tallinn   (estpak.ee):     %s ms\n" "${lat_tallinn:-нет}"
    printf "  Stockholm (sunet.se):      %s ms\n" "${lat_stockholm:-нет}"
    printf "  Riga      (lattelecom.lv): %s ms\n" "${lat_riga:-нет}"
    printf "  Warsaw    (nask.pl):       %s ms\n" "${lat_warsaw:-нет}"
    echo
    echo "Kernel: $kern  Distro: $distro  Virt: $virt  Uptime: $up"

    # Конс-страны — если базы согласны, берём её. Если разногласия — флагаем.
    local countries=""
    [ "$ipinfo_country" != "?" ] && countries="$countries $ipinfo_country"
    [ "$ipapi_country"  != "?" ] && countries="$countries $ipapi_country"
    [ "$ipwho_country"  != "?" ] && countries="$countries $ipwho_country"
    local uniq_countries
    uniq_countries=$(echo "$countries" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' '/' | sed 's:/$::')

    # Угадываем "реальную" локацию по самому маленькому ping'у
    local real_loc="?" real_lat=99999
    for pair in "Helsinki:$lat_helsinki" "Tallinn:$lat_tallinn" "Stockholm:$lat_stockholm" "Riga:$lat_riga" "Warsaw:$lat_warsaw"; do
        local loc=${pair%%:*}
        local lat=${pair##*:}
        [ -z "$lat" ] && continue
        if have bc && (( $(echo "$lat < $real_lat" | bc -l 2>/dev/null || echo 0) )); then
            real_loc=$loc
            real_lat=$lat
        fi
    done

    # Валидация: latency < 10ms = реально рядом, 10-30ms = в регионе, >30ms = непонятно
    local geo_lat_str="?"
    if [ "$real_loc" != "?" ]; then
        if have bc && (( $(echo "$real_lat < 10" | bc -l 2>/dev/null || echo 0) )); then
            geo_lat_str="${real_loc} (~${real_lat} ms, рядом)"
        elif have bc && (( $(echo "$real_lat < 30" | bc -l 2>/dev/null || echo 0) )); then
            geo_lat_str="${real_loc} (~${real_lat} ms, в регионе)"
        else
            geo_lat_str="не определено (все >30ms — туннель/потери искажают)"
        fi
    fi

    summary_kv "Хост"          "$h"
    summary_kv "IP"            "$ip4"
    summary_kv "Гео по базам"  "$uniq_countries"
    summary_kv "Гео по latency" "$geo_lat_str"
    summary_kv "ASN"           "${ipinfo_org:-${ipapi_org}}"
    summary_kv "Ядро"          "$kern · $distro"

    RES_STATUS=ok
    RES_SUMMARY="$h · $uniq_countries"
    [ "$real_loc" != "?" ] && RES_SUMMARY="$RES_SUMMARY · ~${real_lat}ms→$real_loc"

    # Флагаем если разные базы дают разную страну
    local n_uniq
    n_uniq=$(echo "$uniq_countries" | tr '/' '\n' | grep -cv '^$')
    if [ "$n_uniq" -ge 2 ]; then
        RES_STATUS=warn
        finding 1 geo "Базы расходятся по стране ($uniq_countries) — типично для хостинг-IP, регистрация ASN ≠ физический ДЦ. Реальная локация по latency: $real_loc"
    fi
}

# 2. CPU и нагрузка
check_cpu() {
    local nproc model load idle softirq iow
    nproc=$(nproc)
    model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
    load=$(cut -d' ' -f1 /proc/loadavg)

    if have mpstat; then
        local mp
        mp=$(mpstat -P ALL 1 1 2>/dev/null)
        idle=$(echo "$mp"   | awk '/Average:.*all/ {print $NF}')
        iow=$(echo "$mp"    | awk '/Average:.*all/ {print $6}')
        softirq=$(echo "$mp"| awk '/Average:.*all/ {print $9}')
        echo "$mp"
    else
        idle="?"; iow="?"; softirq="?"
        cat /proc/loadavg
    fi

    echo "Cores=$nproc  Model=$model  Load=$load  Idle=${idle}%  Softirq=${softirq}%  iowait=${iow}%"

    summary_kv "CPU" "$nproc cores · $model · load $load"

    RES_STATUS=ok
    RES_SUMMARY="${nproc}c · load $load · idle ${idle}%"

    if have bc; then
        if (( $(echo "$idle < 50" | bc -l 2>/dev/null || echo 0) )); then
            RES_STATUS=warn
            RES_SUMMARY="$RES_SUMMARY · ⚠ перегружен"
            finding 3 cpu "CPU idle ${idle}% — Xray упирается в шифрование, добавь ядра/перенеси нагрузку"
        fi
        if (( $(echo "${softirq:-0} > 15" | bc -l 2>/dev/null || echo 0) )); then
            [ "$RES_STATUS" = "ok" ] && RES_STATUS=warn
            RES_SUMMARY="$RES_SUMMARY · softirq ${softirq}%"
            finding 2 cpu "softirq ${softirq}% — настрой RPS/RSS, иначе одно ядро забьёт прерываниями"
        fi
        if (( $(echo "${iow:-0} > 5" | bc -l 2>/dev/null || echo 0) )); then
            finding 2 cpu "iowait ${iow}% — упор в диск (логи Xray? swap?)"
        fi
    fi
}

# 3. Память
check_mem() {
    free -h
    local avail total pct swap_used
    avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    pct=$((100 * avail / total))
    swap_used=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print t-f}' /proc/meminfo)

    summary_kv "RAM" "$(free -h | awk '/Mem:/ {print $2" total · "$7" available"}')"

    RES_STATUS=ok
    RES_SUMMARY="${pct}% доступно"
    if [ "$pct" -lt 15 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$RES_SUMMARY ⚠"
        finding 2 mem "Свободной памяти <15% — page cache страдает, фризы под нагрузкой"
    fi
    [ "$swap_used" -gt 0 ] && RES_SUMMARY="$RES_SUMMARY · swap used"
}

# 4. NIC / интерфейс
check_nic() {
    local iface mtu drv speed rx_drops tx_drops rx_err tx_err
    iface=$(ip -4 route show default | awk '/default/ {print $5; exit}')
    mtu=$(ip link show "$iface" | grep -oP 'mtu \K\d+')
    drv=$(have ethtool && ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver/ {print $2}')
    speed=$(have ethtool && ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed/ {print $2}')

    rx_drops=$(ip -s link show "$iface" | awk '/RX:/{getline; print $4}')
    tx_drops=$(ip -s link show "$iface" | awk '/TX:/{getline; print $4}')
    rx_err=$(ip -s link show "$iface"   | awk '/RX:/{getline; print $3}')
    tx_err=$(ip -s link show "$iface"   | awk '/TX:/{getline; print $3}')

    echo "iface=$iface  mtu=$mtu  driver=${drv:-?}  speed=${speed:-?}"
    echo "RX errors=$rx_err  drops=$rx_drops"
    echo "TX errors=$tx_err  drops=$tx_drops"
    if have ethtool; then
        echo "--- ethtool -k (offloads) ---"
        ethtool -k "$iface" 2>/dev/null | grep -E '^(rx-|tx-|generic-|tcp-segm|scatter)' | head -10
        echo "--- ring buffers ---"
        ethtool -g "$iface" 2>/dev/null | head -10
        echo "--- ненулевые ошибки/дропы ---"
        ethtool -S "$iface" 2>/dev/null | awk '$NF+0 != 0' | grep -iE 'err|drop|miss|discard|fail|overflow' | head -10
    fi

    summary_kv "NIC" "$iface · ${drv:-?} · mtu $mtu"

    RES_STATUS=ok
    RES_SUMMARY="$iface · mtu $mtu · drops ${rx_drops}/${tx_drops}"

    if [ "$mtu" -lt 1500 ]; then
        finding 2 nic "MTU=$mtu < 1500 — подтоннель или GRE; проверь PMTU"
    fi
    if [ "${rx_drops:-0}" -gt 1000 ]; then
        RES_STATUS=warn
        finding 2 nic "RX drops $rx_drops — буфер интерфейса/ядра не справляется (rx_buffer / netdev_max_backlog)"
    fi
    if [ "${tx_drops:-0}" -gt 1000 ]; then
        RES_STATUS=warn
        finding 2 nic "TX drops $tx_drops — насыщение исходящего канала / qdisc"
    fi
}

# 4b. Туннели (WireGuard / NetBird / Tailscale / OpenVPN / IPsec)
check_tunnel() {
    local tunnels=()
    while IFS= read -r line; do
        local iface
        iface=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
        case "$iface" in
            wg*)         tunnels+=("WireGuard:$iface") ;;
            tun*)        tunnels+=("OpenVPN/tun:$iface") ;;
            tap*)        tunnels+=("OpenVPN/tap:$iface") ;;
            wt*)         tunnels+=("NetBird:$iface") ;;
            tailscale*|ts*) tunnels+=("Tailscale:$iface") ;;
            ipsec*|gre*) tunnels+=("IPsec/GRE:$iface") ;;
        esac
    done < <(ip -o link show 2>/dev/null)

    local def_iface
    def_iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    echo "default iface: $def_iface"

    if [ ${#tunnels[@]} -eq 0 ]; then
        RES_STATUS=ok
        RES_SUMMARY="туннелей нет"
        return
    fi

    echo "Найдены туннели: ${tunnels[*]}"
    local mtu_issue=0 def_via_tunnel=""
    for entry in "${tunnels[@]}"; do
        local kind=${entry%%:*}
        local iface=${entry##*:}
        local mtu peer
        mtu=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+')
        peer=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        echo "  $kind ($iface): MTU=$mtu addr=$peer"

        # NetBird/WireGuard MTU обычно 1280-1420 — нормально, но при 1280 на 1500 underlay будет фрагментация
        if [ -n "$mtu" ] && [ "$mtu" -lt 1280 ]; then
            mtu_issue=1
            finding 2 tunnel "Туннель $iface MTU=$mtu < 1280 — слишком мелкий, потеряешь скорость"
        fi
        if [ "$iface" = "$def_iface" ]; then
            def_via_tunnel=$iface
        fi
    done

    summary_kv "Туннели" "${#tunnels[@]} активных: ${tunnels[*]}"

    if [ -n "$def_via_tunnel" ]; then
        RES_STATUS=warn
        RES_SUMMARY="${#tunnels[@]} активн., default через $def_via_tunnel"
        finding 2 tunnel "Default route идёт через туннель $def_via_tunnel — весь трафик ноды заворачивается в overlay (пиринг ASN не работает напрямую)"
    elif [ "$mtu_issue" = "1" ]; then
        RES_STATUS=warn
        RES_SUMMARY="${#tunnels[@]} активн., MTU мелкий"
    else
        RES_STATUS=ok
        RES_SUMMARY="${#tunnels[@]} активн., default через $def_iface"
        finding 1 tunnel "Активные туннели (${tunnels[*]}). Default не через них — это ок"
    fi
}

# 5. TCP congestion control
check_tcp_cc() {
    local cc qdisc avail
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    qdisc=$(sysctl -n net.core.default_qdisc)
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    echo "cc=$cc  qdisc=$qdisc"
    echo "available=$avail"

    summary_kv "TCP CC" "$cc + $qdisc"

    RES_STATUS=ok
    RES_SUMMARY="$cc + $qdisc"
    if [ "$cc" != "bbr" ]; then
        if echo "$avail" | grep -q bbr; then
            RES_STATUS=warn
            RES_SUMMARY="$cc (bbr доступен!)"
            finding 1 tcp "Используется $cc; BBR доступен как опциональная альтернатива, но это не самостоятельная неисправность"
        else
            RES_STATUS=warn
            RES_SUMMARY="bbr недоступен"
            finding 1 tcp "BBR отсутствует в списке доступных алгоритмов; cubic остаётся рабочим вариантом"
        fi
    fi
    case "$qdisc" in
        fq|fq_codel|cake) ;;
        *)
            [ "$RES_STATUS" = "ok" ] && RES_STATUS=warn
            finding 2 tcp "qdisc=$qdisc — для BBR нужен fq, для bufferbloat — fq_codel/cake"
            ;;
    esac
}

# 6. TCP tuning
check_tcp_tuning() {
    local mtu_probe slow_start rmem_max wmem_max ntsl backlog
    mtu_probe=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)
    slow_start=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    ntsl=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
    backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)

    echo "tcp_mtu_probing=$mtu_probe"
    echo "tcp_slow_start_after_idle=$slow_start"
    echo "rmem_max=$rmem_max  wmem_max=$wmem_max"
    echo "tcp_notsent_lowat=$ntsl"
    echo "netdev_max_backlog=$backlog"
    sysctl -a 2>/dev/null | grep -E '^net\.ipv4\.(tcp_window_scaling|tcp_sack|tcp_timestamps|tcp_fastopen|tcp_ecn|tcp_no_metrics_save)' || true

    local issues=()
    [ "$mtu_probe" = "0" ] && issues+=("mtu_probing=0")
    [ "$slow_start" = "1" ] && issues+=("slow_start=1")
    [ "$rmem_max" -lt 16777216 ] && issues+=("rmem_max=$rmem_max")
    [ "${backlog:-0}" -lt 4096 ] && issues+=("backlog=$backlog")

    if [ ${#issues[@]} -eq 0 ]; then
        RES_STATUS=ok
        RES_SUMMARY="всё ок"
    else
        RES_STATUS=warn
        RES_SUMMARY="$(IFS=, ; echo "${issues[*]}")"
        [ "$mtu_probe" = "0" ] && finding 3 tcp "tcp_mtu_probing=0 — при PMTU-blackhole TCP-сессии виснут (классика «зависшая подгрузка»)"
        [ "$slow_start" = "1" ] && finding 2 tcp "tcp_slow_start_after_idle=1 — после паузы скорость падает в slow-start. Лучше 0"
        [ "$rmem_max" -lt 16777216 ] && finding 2 tcp "rmem_max=$rmem_max < 16M — на гиг-канале мелкое TCP-окно режет скорость"
        [ "${backlog:-0}" -lt 4096 ] && finding 1 tcp "netdev_max_backlog=$backlog — мало под нагрузку, рекомендую 16384"
    fi

    summary_kv "TCP tuning" "$RES_SUMMARY"
}

# 7. Conntrack
check_conntrack() {
    if [ ! -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        RES_STATUS=skip
        RES_SUMMARY="conntrack модуль не загружен"
        return
    fi
    local cur max pct
    cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    pct=$((100 * cur / (max > 0 ? max : 1)))
    echo "count=$cur max=$max ($pct%)"
    if have conntrack; then
        echo "--- топ-10 dst ---"
        conntrack -L 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) {gsub("dst=","",$i); print $i; break}}' \
            | sort | uniq -c | sort -rn | head -10
    fi

    summary_kv "Conntrack" "$cur / $max ($pct%)"

    RES_STATUS=ok
    RES_SUMMARY="$cur / $max ($pct%)"
    if [ "$pct" -ge 80 ]; then
        RES_STATUS=bad
        finding 3 conntrack "Conntrack заполнен на $pct% — новые соединения дропаются. Это и есть «шортсы не открываются». nf_conntrack_max → 524288"
    elif [ "$pct" -ge 50 ]; then
        RES_STATUS=warn
        finding 1 conntrack "Conntrack использован на $pct% — близко к лимиту"
    fi
}

# 8. DNS
check_dns() {
    cat /etc/resolv.conf 2>/dev/null
    local fail=0 total=0 lat_sum=0
    if have dig; then
        echo "--- 5 запросов youtube.com ---"
        for _ in 1 2 3 4 5; do
            total=$((total+1))
            local ans t
            ans=$(dig +short +time=2 +tries=1 youtube.com A 2>/dev/null | head -1)
            t=$(dig +tries=1 +time=2 youtube.com A 2>/dev/null | awk '/Query time/ {print $4}')
            echo "  ans=$ans  ${t:-?}ms"
            if [ -z "$ans" ]; then
                fail=$((fail+1))
            elif [ -n "$t" ]; then
                lat_sum=$((lat_sum + t))
            fi
        done
        echo "--- основные хосты ---"
        for host in www.google.com youtube.com googlevideo.com www.youtube.com i.ytimg.com; do
            local a4 a6
            a4=$(dig +short +time=2 +tries=1 "$host" A 2>/dev/null | head -1)
            a6=$(dig +short +time=2 +tries=1 "$host" AAAA 2>/dev/null | head -1)
            printf "  %-25s A=%-20s AAAA=%s\n" "$host" "${a4:-—}" "${a6:-—}"
        done
    fi

    summary_kv "DNS" "$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)"

    if [ "$total" -eq 0 ]; then
        RES_STATUS=skip
        RES_SUMMARY="(dig недоступен)"
    elif [ "$fail" -gt 0 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$fail/$total попыток с фейлом"
        finding 3 dns "DNS таймаутит ($fail/$total) — резолв googlevideo фейлится → клиент попадает на старый/медленный PoP"
    else
        local avg=$((lat_sum / total))
        RES_SUMMARY="${avg}ms среднее"
        RES_STATUS=ok
        [ "$avg" -gt 100 ] && { RES_STATUS=warn; finding 1 dns "DNS-латенси ${avg}ms — медленный резолвер"; }
    fi
}

# 9. PMTU (бинарный поиск)
check_pmtu() {
    # Робаст-проба: считаем размер OK если хотя бы 1 из 3 пакетов вернулся.
    # Иначе на сети с потерями single-shot ping ловит false-negative и сходимость врёт.
    pmtu_probe() {
        local size=$1 target=${2:-1.1.1.1}
        local recv
        recv=$(ping -M do -s "$size" -c 3 -W 2 "$target" 2>/dev/null | awk '/packets transmitted/ {print $4}')
        [ "${recv:-0}" -ge 1 ]
    }

    if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        RES_STATUS=skip
        RES_SUMMARY="ICMP недоступен — PMTU не измерен"
        summary_kv "PMTU" "не измерен"
        return
    fi

    echo "ping -M do -s 1472 → 1.1.1.1 (3 пакета)"
    if pmtu_probe 1472; then
        RES_STATUS=ok
        RES_SUMMARY="PMTU 1500 (full)"
        summary_kv "PMTU" "1500"
        return
    fi

    local hi=1472 lo=576 best=0 mid
    for _ in $(seq 1 12); do
        mid=$(( (hi + lo) / 2 ))
        if pmtu_probe "$mid"; then
            best=$mid; lo=$mid
        else
            hi=$mid
        fi
        [ $((hi - lo)) -le 1 ] && break
    done
    local mtu=$((best + 28))
    echo "Максимальный безфраг payload: $best (=> path MTU ~$mtu)"

    summary_kv "PMTU" "$mtu"

    RES_STATUS=warn
    RES_SUMMARY="$mtu (вместо 1500)"
    if [ "$mtu" -lt 1450 ]; then
        RES_STATUS=bad
        finding 3 pmtu "PMTU=$mtu — большие пакеты теряются. Нужно: tcp_mtu_probing=1 + iptables TCPMSS clamp"
    else
        finding 2 pmtu "PMTU=$mtu < 1500 — включи tcp_mtu_probing=1 чтоб TCP не висел на blackhole"
    fi
}

# 10. Loss / latency до google
check_loss() {
    # Извлекает loss% из вывода ping — ищем токен вида "20%"
    parse_loss() {
        echo "$1" | awk '/packet loss/ {
            for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+)?%$/) {
                sub("%","",$i); printf "%d", $i+0; exit
            }
        }'
    }
    local g_loss=0 failed_targets=0 measured=0
    for host in 8.8.8.8 1.1.1.1 9.9.9.9 www.google.com youtube.com googlevideo.com; do
        local out loss rtt
        out=$(ping -c 10 -W 2 -i 0.2 -q "$host" 2>/dev/null)
        loss=$(parse_loss "$out")
        rtt=$(echo "$out"  | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5}')
        echo "  $host loss=${loss:-?}% avg=${rtt:-?}ms"
        if [ -z "$loss" ]; then
            failed_targets=$((failed_targets + 1))
            continue
        fi
        measured=$((measured + 1))
        [ "${loss:-0}" -gt "$g_loss" ] && g_loss=$loss
    done

    summary_kv "Loss до Google" "max ${g_loss}%"

    RES_STATUS=ok
    RES_SUMMARY="max ${g_loss}% loss · ${failed_targets} без ответа"
    if [ "$measured" -eq 0 ] || [ "$failed_targets" -ge 3 ]; then
        RES_STATUS=bad
        finding 3 loss "Не отвечают ${failed_targets} из 6 контрольных адресов — ICMP заблокирован или сеть/DNS недоступны"
    elif [ "$g_loss" -ge 5 ]; then
        RES_STATUS=bad
        finding 3 loss "Потери до Google до ${g_loss}% — TCP retransmits, видео фризит. Проблема пиринга провайдера"
    elif [ "$g_loss" -gt 0 ]; then
        RES_STATUS=warn
        finding 2 loss "Лёгкие потери до Google (${g_loss}%) — на грани"
    fi
}

# 11. MTR — ищем худший хоп
check_mtr() {
    have mtr || { RES_STATUS=skip; RES_SUMMARY="mtr недоступен"; return; }
    local out worst_loss hops_total final_loss final_hop
    out=$(mtr -r -c 15 -n youtube.com 2>/dev/null)
    echo "$out"
    # mtr-строка: "  3.|-- 100.64.120.0   0.0%  15  ..."
    # Литеральный `|` в ERE — через [|] (a `\|` некоторые grep-и ловят как альтернацию).
    hops_total=$(echo "$out" | grep -cE '^ *[0-9]+\.[|]')
    worst_loss=$(echo "$out" | awk '
        BEGIN { max = -1 }
        /^ *[0-9]+\.[|]/ {
            gsub("%","",$3)
            if ($3+0 > max) { max=$3+0; hop=$2"/"$3"%" }
        }
        END { print hop }')
    final_hop=$(echo "$out" | awk '/^ *[0-9]+\.[|]/ {line=$0} END {print line}')
    final_loss=$(echo "$final_hop" | awk '{gsub("%","",$3); print $3+0}')

    echo
    echo "--- mtr → googlevideo.com ---"
    mtr -r -c 15 -n googlevideo.com 2>/dev/null

    summary_kv "Маршрут" "$hops_total hops · endpoint loss ${final_loss:-?}%"

    RES_STATUS=ok
    RES_SUMMARY="$hops_total hops"
    if [ -n "$final_loss" ] && [ "$final_loss" -ge 30 ]; then
        RES_STATUS=bad
        RES_SUMMARY="${hops_total}h · endpoint loss ${final_loss}%"
        finding 3 route "Конечный узел MTR теряет ${final_loss}% пакетов; потери промежуточных хопов отдельно не считаются неисправностью"
    elif [ -n "$final_loss" ] && [ "$final_loss" -ge 10 ]; then
        RES_STATUS=warn
        RES_SUMMARY="${hops_total}h · endpoint loss ${final_loss}%"
        finding 2 route "На конечном узле MTR наблюдается ${final_loss}% потерь"
    elif [ -n "$worst_loss" ]; then
        echo "Потери на промежуточных хопах ($worst_loss) не учитываются без потерь на конечном узле."
    fi
}

# 12. UDP / QUIC / HTTP/3
check_quic() {
    local h3_ok=0
    if ! curl --help all 2>/dev/null | grep -q -- '--http3-only'; then
        RES_STATUS=skip
        RES_SUMMARY="curl собран без HTTP/3"
        summary_kv "QUIC/HTTP3" "не проверен"
        return
    fi
    if curl --http3-only -sS -o /dev/null --max-time 8 https://www.youtube.com >/dev/null 2>&1; then
        h3_ok=1
    fi
    echo "HTTP/3 youtube.com: $([ "$h3_ok" -eq 1 ] && echo OK || echo FAIL)"
    summary_kv "QUIC/HTTP3" "$([ "$h3_ok" -eq 1 ] && echo on || echo off)"
    if [ "$h3_ok" -eq 1 ]; then
        RES_STATUS=ok
        RES_SUMMARY="HTTP/3 доступен"
    else
        RES_STATUS=warn
        RES_SUMMARY="HTTP/3 не установился"
        finding 2 quic "Реальное HTTP/3-соединение не установилось; UDP-проверка через nc не используется как недостоверная"
    fi
}

# 13. Скорость: одиночный поток (Cachefly 100 МБ)
check_speed_single() {
    local out spd_bps spd_mbit code size size_int curl_rc=0
    out=$(curl "${CURL_FLAGS[@]}" -sS -o /dev/null --max-time 12 \
        -w "%{speed_download}|%{size_download}|%{time_total}|%{http_code}" \
        "https://cachefly.cachefly.net/100mb.test" 2>/dev/null) || curl_rc=$?
    echo "raw: $out"
    spd_bps=$(echo "$out" | cut -d'|' -f1)
    size=$(echo    "$out" | cut -d'|' -f2)
    size_int=${size%%.*}
    size_int=${size_int:-0}
    code=$(echo    "$out" | cut -d'|' -f4)
    # curl при таймауте отдаёт "0.000" — приводим к целому
    local spd_int
    spd_int=$(printf '%.0f' "${spd_bps:-0}" 2>/dev/null || echo 0)
    if [ -z "$spd_bps" ] || [ "${spd_int:-0}" -lt 10000 ] || [ "$size_int" -lt 500000 ] || [[ "$code" != 200 && "$code" != 206 ]]; then
        RES_STATUS=bad
        RES_SUMMARY="fail (size=${size:-?}, http=${code:-?})"
        finding 3 speed "Cachefly не передал достаточно данных (${size:-0} bytes, http=${code:-?}, curl=$curl_rc)"
        summary_kv "Speed (1-flow)" "fail"
        return
    fi
    spd_mbit=$(( spd_int * 8 / 1000000 ))

    summary_kv "Speed (1-flow)" "${spd_mbit} Mbit/s"

    RES_STATUS=ok
    RES_SUMMARY="${spd_mbit} Mbit/s"
    if [ "${spd_mbit:-0}" -lt 50 ]; then
        RES_STATUS=bad
        finding 3 speed "1-flow ${spd_mbit} Mbit/s — очень низкая скорость, видео не пойдёт"
    elif [ "${spd_mbit:-0}" -lt 200 ]; then
        RES_STATUS=warn
        finding 2 speed "1-flow ${spd_mbit} Mbit/s — нода работает, но шортсы могут запинаться при многих юзерах"
    fi
}

# 14. Скорость: 4 параллельных потока
check_speed_4flow() {
    local tmpd
    tmpd=$(mktemp -d)
    local PIDS=()
    local start
    start=$(date +%s)
    for i in 1 2 3 4; do
        ( curl "${CURL_FLAGS[@]}" -o "$tmpd/d$i" --max-time 10 -sS \
            "https://cachefly.cachefly.net/100mb.test" >/dev/null 2>&1 ) &
        PIDS+=($!)
    done
    local deadline=$(( start + 12 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local running=0
        for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && running=1; done
        [ "$running" = "0" ] && break
        sleep 1
    done
    local end
    end=$(date +%s)
    for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done

    local dur total=0 sz
    dur=$(( end - start )); [ "$dur" -lt 1 ] && dur=1
    for f in "$tmpd"/d*; do
        [ -f "$f" ] || continue
        sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        total=$((total + sz))
    done
    rm -rf "$tmpd"

    if [ "$total" -eq 0 ]; then
        RES_STATUS=bad
        RES_SUMMARY="fail (Cachefly недоступен)"
        finding 2 speed "4-flow тест не получил данные — параллельные TLS-сессии режутся?"
        summary_kv "Speed (4-flow)" "fail"
        return
    fi
    local mbits
    mbits=$(echo "scale=0; $total * 8 / $dur / 1000000 / 1" | bc -l 2>/dev/null)
    echo "4-flow combined: $mbits Mbit/s ($total bytes за ${dur}s)"

    summary_kv "Speed (4-flow)" "${mbits} Mbit/s"

    RES_STATUS=ok
    RES_SUMMARY="${mbits} Mbit/s combined"
    if [ "$mbits" -lt 100 ]; then
        RES_STATUS=warn
        finding 2 speed "4-flow всего ${mbits} Mbit/s — канал маленький либо троттлит"
    fi
}

# 15. Bufferbloat
check_bufferbloat() {
    local base under
    base=$(ping -c 10 -i 0.2 -W 2 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5}')
    echo "baseline avg: ${base:-?} ms"

    # Считаем сколько реально скачали — иначе тест без нагрузки бессмысленен
    local load_file
    load_file=$(mktemp)
    ( curl "${CURL_FLAGS[@]}" --max-time 12 -sS -o "$load_file" \
        "https://cachefly.cachefly.net/100mb.test" >/dev/null 2>&1 ) &
    local DL=$!
    sleep 1
    under=$(ping -c 12 -i 0.2 -W 2 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5}')
    local deadline=$(( $(date +%s) + 4 ))
    while kill -0 "$DL" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
    kill -TERM "$DL" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$DL" 2>/dev/null || true
    wait "$DL" 2>/dev/null || true

    local downloaded
    downloaded=$(stat -c '%s' "$load_file" 2>/dev/null || echo 0)
    rm -f "$load_file"
    echo "under load avg: ${under:-?} ms · downloaded ${downloaded} bytes"

    # Если download не дошёл хотя бы до 5 МБ — линк не нагрузился, мерять нечего
    if [ "${downloaded:-0}" -lt 5000000 ]; then
        RES_STATUS=skip
        RES_SUMMARY="download fail (${downloaded:-0} bytes) — нагрузка не пошла"
        finding 1 bufferbloat "Не удалось загрузить канал для измерения bufferbloat (Cachefly blocked? канал упал?)"
        return
    fi

    if [ -z "$base" ] || [ -z "$under" ]; then
        RES_STATUS=skip
        RES_SUMMARY="(ping не дал результат)"
        return
    fi

    local delta
    delta=$(echo "scale=0; ($under - $base) / 1" | bc -l 2>/dev/null)

    # Аккуратный знак (избегаем "+-31 ms")
    local sign
    if [ "${delta:0:1}" = "-" ]; then
        sign=""   # минус уже в значении
    elif [ "${delta:-0}" -gt 0 ] 2>/dev/null; then
        sign="+"
    else
        sign=""
    fi

    summary_kv "Bufferbloat" "${sign}${delta} ms"

    RES_STATUS=ok
    RES_SUMMARY="${sign}${delta} ms"

    # Отрицательная дельта (под нагрузкой ниже baseline) = странность сети, не bufferbloat
    if [ "${delta:0:1}" = "-" ]; then
        RES_SUMMARY="${delta} ms (странно: ping упал под нагрузкой)"
        finding 1 bufferbloat "Под нагрузкой ping ниже baseline — нестабильная сеть, baseline захватил случайный спайк"
        return
    fi

    if have bc && (( $(echo "$delta > 100" | bc -l) )); then
        RES_STATUS=bad
        finding 3 bufferbloat "Bufferbloat +${delta} ms — катастрофа, шортсы будут постоянно фризить. Лечится qdisc=cake/fq_codel"
    elif have bc && (( $(echo "$delta > 50" | bc -l) )); then
        RES_STATUS=bad
        finding 3 bufferbloat "Bufferbloat +${delta} ms — большой. Включи qdisc cake"
    elif have bc && (( $(echo "$delta > 20" | bc -l) )); then
        RES_STATUS=warn
        finding 2 bufferbloat "Bufferbloat +${delta} ms — заметный, на грани"
    fi
}

# 16. Sustained variance — детект троттлинга
check_variance() {
    local samples=()
    local fails=0
    for i in 1 2 3 4 5; do
        local spd spd_int
        spd=$(curl "${CURL_FLAGS[@]}" -sS -o /dev/null --max-time 5 \
            -w "%{speed_download}" "https://cachefly.cachefly.net/100mb.test" 2>/dev/null) || true
        spd_int=$(printf '%.0f' "${spd:-0}" 2>/dev/null || echo 0)
        if [ -z "$spd" ] || [ "${spd_int:-0}" -lt 10000 ]; then
            fails=$((fails+1))
            samples+=("0")
            echo "  $i: fail (${spd_int}B/s)"
        else
            local mbit
            mbit=$(( spd_int * 8 / 1000000 ))
            samples+=("$mbit")
            echo "  $i: ${mbit} Mbit/s"
        fi
    done

    if [ "$fails" -ge 5 ]; then
        # Все упали — скорее проблема канала/блокировки cachefly, не нестабильность
        RES_STATUS=warn
        RES_SUMMARY="5/5 fail"
        finding 2 variance "Все 5 заборов Cachefly упали — Cachefly блокируется этим ASN или канал крайне нестабилен (проверь раздел CDN — если только Cachefly fail, это не катастрофа)"
        summary_kv "Variance (5x)" "5 fails"
        return
    elif [ "$fails" -ge 3 ]; then
        RES_STATUS=bad
        RES_SUMMARY="$fails/5 fail"
        finding 3 variance "$fails/5 заборов фейл — канал/маршрут крайне нестабильный"
        summary_kv "Variance (5x)" "$fails fails"
        return
    fi

    local min=999999 max=0 v
    for v in "${samples[@]}"; do
        [ "$v" = "0" ] && continue
        [ "$v" -lt "$min" ] && min=$v
        [ "$v" -gt "$max" ] && max=$v
    done
    local ratio
    ratio=$(echo "scale=1; $max / ($min > 0 ? $min : 1)" | bc -l)
    echo "min=${min} max=${max} ratio=${ratio}x"

    summary_kv "Variance (5x)" "${min}–${max} Mbit/s (${ratio}x)"

    RES_STATUS=ok
    RES_SUMMARY="${min}–${max} Mbit/s"
    if have bc && (( $(echo "$ratio > 3" | bc -l) )); then
        RES_STATUS=bad
        finding 3 variance "Разброс x${ratio} — Google троттлит ASN или PoP-роутинг нестабилен"
    elif have bc && (( $(echo "$ratio > 2" | bc -l) )); then
        RES_STATUS=warn
        finding 2 variance "Разброс x${ratio} — нестабильный канал"
    fi
}

# 17. TCP retransmissions
check_tcp_stats() {
    # Диагностический дамп (не используем для счёта — `nstat -r` обнуляет кеш)
    have nstat && nstat -rsz 2>/dev/null \
        | grep -iE 'TcpRetrans|TcpExt.*Retrans|TcpAttemptFails|ListenDrops|TCPBacklogDrop|OutOfOrder' \
        | head -20

    # Абсолютные счётчики читаем напрямую из /proc/net/snmp.
    # Tcp-строка: # столбцы 11=InSegs 12=OutSegs 13=RetransSegs (см. RFC2012/MIB-II).
    local seg out_seg retrans pct=0
    if [ -r /proc/net/snmp ]; then
        local snmp_vals
        snmp_vals=$(awk '/^Tcp:/ {n++} n==2 {print; exit}' /proc/net/snmp)
        seg=$(echo     "$snmp_vals" | awk '{print $11}')
        out_seg=$(echo "$snmp_vals" | awk '{print $12}')
        retrans=$(echo "$snmp_vals" | awk '{print $13}')
    fi
    if [ -n "${out_seg:-}" ] && [ "${out_seg:-0}" -gt 0 ] && [ -n "${retrans:-}" ]; then
        pct=$(echo "scale=2; $retrans * 100 / $out_seg" | bc -l 2>/dev/null)
    fi
    echo "InSegs=${seg:-?} OutSegs=${out_seg:-?} Retrans=${retrans:-?} (${pct}%)"

    if [ -z "${seg:-}" ]; then
        RES_STATUS=skip
        RES_SUMMARY="(не удалось прочитать /proc/net/snmp)"
        return
    fi

    summary_kv "TCP retrans" "${pct}% ($retrans/$out_seg)"

    RES_STATUS=ok
    RES_SUMMARY="${pct}% retrans"
    if have bc && (( $(echo "$pct > 5" | bc -l 2>/dev/null || echo 0) )); then
        RES_STATUS=bad
        finding 3 retrans "TCP retrans ${pct}% — очень много, явные потери на маршруте"
    elif have bc && (( $(echo "$pct > 2" | bc -l 2>/dev/null || echo 0) )); then
        RES_STATUS=warn
        finding 2 retrans "TCP retrans ${pct}% — заметные потери на пути"
    fi
}

# 18. IPv6 готовность
check_ipv6() {
    local v6_route v6_ext v6_ping
    v6_route=$(ip -6 route show default 2>/dev/null | head -1)
    v6_ext=$(curl --connect-timeout 5 -6 -sS --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
    if [ -z "$v6_ext" ]; then
        RES_STATUS=warn
        RES_SUMMARY="нет IPv6"
        finding 1 ipv6 "IPv6 не настроен. Google отдаёт PoP по v6 быстрее → клиент попадает на медленный v4"
        summary_kv "IPv6" "нет"
        return
    fi
    v6_ping=$(ping -6 -c 4 -W 2 -q ipv6.google.com 2>/dev/null | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5}')
    echo "v6 external: $v6_ext"
    echo "v6 ping ipv6.google.com: ${v6_ping:-fail}ms"
    summary_kv "IPv6" "$v6_ext · ${v6_ping:-?}ms"
    RES_STATUS=ok
    RES_SUMMARY="$v6_ext · ${v6_ping:-?}ms"
}

# 19. Reachability популярных сервисов (TTFB + HTTP-код)
check_services() {
    local SERVICES=(
        "YouTube|https://www.youtube.com/"
        "Google|https://www.google.com/"
        "Netflix|https://www.netflix.com/"
        "Twitch|https://www.twitch.tv/"
        "TikTok|https://www.tiktok.com/"
        "Instagram|https://www.instagram.com/"
        "Twitter/X|https://x.com/"
        "Telegram-Web|https://web.telegram.org/"
        "Telegram-API|https://api.telegram.org/"
        "Discord|https://discord.com/api/v9/gateway"
        "WhatsApp|https://web.whatsapp.com/"
        "Signal|https://signal.org/"
        "ChatGPT|https://chat.openai.com/"
        "Claude|https://claude.ai/"
        "Gemini|https://gemini.google.com/"
        "Spotify|https://open.spotify.com/"
        "Steam|https://store.steampowered.com/"
        "GitHub|https://github.com/"
        "Reddit|https://www.reddit.com/"
    )

    local fails=0 blocked=0 slow=0 ok_count=0 total=0
    local failed_list="" blocked_list="" slow_list=""

    for entry in "${SERVICES[@]}"; do
        local name=${entry%%|*}
        local url=${entry##*|}
        total=$((total+1))
        local out code ttfb
        out=$(curl "${CURL_FLAGS[@]}" -sS -L -o /dev/null --max-time 8 \
            -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
            -w "%{http_code}|%{time_starttransfer}" "$url" 2>/dev/null) || out="000|0"
        code=${out%%|*}
        ttfb=$(echo "${out##*|}" | awk '{printf "%.0f", $1 * 1000}')

        case "$code" in
            2??|3??|400|401|404)
                ok_count=$((ok_count+1))
                if [ "${ttfb:-0}" -gt 2000 ]; then
                    slow=$((slow+1))
                    slow_list="$slow_list $name"
                    printf "  %-15s %s %3sms ${Y}slow${NC}\n" "$name" "$code" "$ttfb"
                else
                    printf "  %-15s %s %3sms\n" "$name" "$code" "$ttfb"
                fi
                ;;
            403|429|451)
                blocked=$((blocked+1))
                blocked_list="$blocked_list $name($code)"
                printf "  %-15s ${R}%s blocked${NC}\n" "$name" "$code"
                ;;
            000)
                fails=$((fails+1))
                failed_list="$failed_list $name"
                printf "  %-15s ${R}unreachable${NC}\n" "$name"
                ;;
            *)
                printf "  %-15s ${Y}%s${NC} %3sms\n" "$name" "$code" "$ttfb"
                ;;
        esac
    done

    summary_kv "Сервисы" "$ok_count/$total ok · $blocked blocked · $fails fail"

    if [ "$fails" -ge 3 ]; then
        RES_STATUS=bad
        RES_SUMMARY="$ok_count/$total · ${fails} unreachable"
        finding 3 services "Недоступны:$failed_list — серьёзная сетевая проблема или DNS"
    elif [ "$blocked" -ge 3 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$ok_count/$total · ${blocked} blocked"
        finding 2 services "Сервисы блокируют IP:$blocked_list — IP в datacenter blacklist'ах"
    elif [ "$fails" -gt 0 ] || [ "$blocked" -gt 0 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$ok_count/$total · $((fails+blocked)) issues"
        [ -n "$failed_list" ]  && finding 2 services "Недоступны:$failed_list"
        [ -n "$blocked_list" ] && finding 2 services "Заблокировали IP:$blocked_list"
    elif [ "$slow" -ge 3 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$ok_count/$total · ${slow} slow"
        finding 1 services "Медленный TTFB:$slow_list (>2s) — возможно плохой пиринг или CDN-маршрут"
    else
        RES_STATUS=ok
        RES_SUMMARY="$ok_count/$total reachable"
    fi
}

# 20. Скорость через несколько CDN (детект ASN-троттлинга)
check_cdn_multi() {
    local CDNS=(
        "Cloudflare|https://speed.cloudflare.com/__down?bytes=20000000"
        "Cachefly|https://cachefly.cachefly.net/10mb.test"
        "Hetzner|https://speed.hetzner.de/100MB.bin"
        "OVH|https://proof.ovh.net/files/100Mb.dat"
        "Linode-LON|https://speedtest.london.linode.com/100MB-london.bin"
    )

    local fastest=0 fastest_name="" slowest=999999999 slowest_name=""
    local total=0 ok=0 sum_mbit=0
    local results=()
    for entry in "${CDNS[@]}"; do
        local name=${entry%%|*}
        local url=${entry##*|}
        total=$((total+1))
        local spd code
        local out
        out=$(curl "${CURL_FLAGS[@]}" -sS -o /dev/null --max-time 8 \
            -w "%{speed_download}|%{http_code}" "$url" 2>/dev/null) || true
        [ -n "$out" ] || out="0|000"
        spd=${out%%|*}
        code=${out##*|}
        # curl возвращает "0.000" при таймауте/ошибке — нормализуем к целому
        local spd_int
        spd_int=$(printf '%.0f' "${spd:-0}" 2>/dev/null || echo 0)
        if [ "${spd_int:-0}" -lt 10000 ] || [ "$code" != "200" ]; then
            printf "  %-12s ${R}fail${NC} (http=$code, ${spd_int}B/s)\n" "$name"
            results+=("$name|fail")
            continue
        fi
        ok=$((ok+1))
        local mbit
        mbit=$(( spd_int * 8 / 1000000 ))
        sum_mbit=$((sum_mbit + mbit))
        printf "  %-12s ${G}%s Mbit/s${NC}\n" "$name" "$mbit"
        results+=("$name|$mbit")
        if [ "$mbit" -gt "$fastest" ]; then fastest=$mbit; fastest_name=$name; fi
        if [ "$mbit" -lt "$slowest" ]; then slowest=$mbit; slowest_name=$name; fi
    done

    if [ "$ok" -eq 0 ]; then
        RES_STATUS=bad
        RES_SUMMARY="все CDN fail"
        finding 3 cdn "Ни один CDN не отвечает — серьёзная блокировка/потеря маршрута"
        return
    fi

    local avg=$((sum_mbit / ok))
    summary_kv "CDN speed" "avg ${avg} Mbit/s · max ${fastest} (${fastest_name})"

    RES_STATUS=ok
    RES_SUMMARY="avg ${avg} Mbit/s · range ${slowest}–${fastest}"
    if [ "$avg" -lt 50 ]; then
        RES_STATUS=bad
        finding 3 cdn "Средняя скорость по CDN ${avg} Mbit/s — канал/пиринг битый"
    elif [ "$avg" -lt 200 ]; then
        RES_STATUS=warn
        finding 2 cdn "CDN avg ${avg} Mbit/s — небыстро для VPN-ноды"
    fi

    # Огромный разброс (одни CDN летят, другие тонут) = разная маршрутизация
    if [ "$fastest" -gt 0 ] && [ "$slowest" -gt 0 ]; then
        local ratio=$((fastest / slowest))
        if [ "$ratio" -ge 5 ]; then
            finding 2 cdn "Разброс x${ratio} между CDN ($slowest_name=$slowest, $fastest_name=$fastest Mbit/s) — значит пиринг разный, какие-то ASN режутся"
        fi
    fi
}

# 21. IP-репутация и видимость снаружи
check_ip_rep() {
    local trace cf_ip cf_loc cf_colo cf_warp cf_h
    trace=$(curl --connect-timeout 5 -sS --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    if [ -z "$trace" ]; then
        RES_STATUS=warn
        RES_SUMMARY="Cloudflare trace недоступен"
        finding 1 reputation "Не удалось получить /cdn-cgi/trace — Cloudflare не отвечает"
        return
    fi
    cf_ip=$(echo "$trace"   | awk -F= '/^ip=/   {print $2}')
    cf_loc=$(echo "$trace"  | awk -F= '/^loc=/  {print $2}')
    cf_colo=$(echo "$trace" | awk -F= '/^colo=/ {print $2}')
    cf_warp=$(echo "$trace" | awk -F= '/^warp=/ {print $2}')
    cf_h=$(echo "$trace"    | awk -F= '/^h=/    {print $2}')

    echo "Cloudflare trace: ip=$cf_ip loc=$cf_loc colo=$cf_colo warp=$cf_warp h=$cf_h"

    # ipapi.co — у них есть поле privacy.hosting / asn.type
    local ipinfo=""
    if have jq; then
        ipinfo=$(curl --connect-timeout 5 -sS --max-time 5 "https://ipapi.co/$cf_ip/json/" 2>/dev/null)
    fi
    local org="" country="" city=""
    if [ -n "$ipinfo" ] && have jq; then
        org=$(echo "$ipinfo"     | jq -r '.org // ""')
        country=$(echo "$ipinfo" | jq -r '.country_name // ""')
        city=$(echo "$ipinfo"    | jq -r '.city // ""')
        echo "ipapi: org=$org country=$country city=$city"
    fi

    # Тест Google CAPTCHA: если IP помечен как абуз — Google вернёт 429 или /sorry/
    local g_test
    g_test=$(curl "${CURL_FLAGS[@]}" -sS -L -o /dev/null --max-time 5 \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        -w "%{http_code}|%{url_effective}" "https://www.google.com/search?q=test" 2>/dev/null)
    local g_code g_url
    g_code=${g_test%%|*}
    g_url=${g_test##*|}
    echo "Google search test: code=$g_code url=$g_url"

    local captcha_hit=0
    if [ "$g_code" = "429" ] || echo "$g_url" | grep -qE 'sorry/|/sorry|captcha'; then
        captcha_hit=1
    fi

    # Reverse-DNS — если PTR содержит "hosting"/"vps"/"server"/"datacenter" — почти точно дата-центр
    # Сначала пробуем системный DNS, при фейле — fallback на 1.1.1.1 (дефолтный DNS ноды может быть кривым)
    local ptr=""
    if have dig && [ -n "$cf_ip" ]; then
        ptr=$(dig +short +time=2 +tries=1 -x "$cf_ip" 2>/dev/null \
            | grep -vE '^;;|^$' | head -1)
        if [ -z "$ptr" ]; then
            ptr=$(dig @1.1.1.1 +short +time=2 +tries=1 -x "$cf_ip" 2>/dev/null \
                | grep -vE '^;;|^$' | head -1)
        fi
        echo "PTR: ${ptr:-нет}"
    fi

    summary_kv "Cloudflare colo" "$cf_colo / $cf_loc"
    summary_kv "Reverse DNS" "${ptr:-нет}"
    [ -z "$ptr" ] && finding 1 reputation "Reverse DNS не резолвится — DNS на ноде сломан или у IP нет PTR"

    RES_STATUS=ok
    RES_SUMMARY="cf=$cf_colo/$cf_loc"

    if [ "$captcha_hit" = "1" ]; then
        RES_STATUS=bad
        RES_SUMMARY="$RES_SUMMARY · Google показывает CAPTCHA"
        finding 3 reputation "Google делает редирект на /sorry — IP в abuse-листах. Юзеры будут видеть капчу"
    fi

    # Эвристика "это датацентр?"
    local dc=0
    if echo "$org $ptr" | grep -qiE 'hosting|datacenter|data.center|vps|server|cloud|colo|dedicated'; then
        dc=1
    fi
    if [ "$dc" = "1" ]; then
        finding 1 reputation "IP выглядит как датацентр (org/ptr содержит hosting/vps) — Netflix/Disney+/банкинг могут блокировать"
    fi
}

# 22. Xray / Remnanode
check_xray() {
    if ! have docker; then RES_STATUS=skip; RES_SUMMARY="docker не найден"; return; fi
    local cont
    cont=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'remnanode|xray|x-ui|sing-box' | head -1)
    if [ -z "$cont" ]; then RES_STATUS=skip; RES_SUMMARY="контейнер не найден"; return; fi

    local ver stats restarts
    ver=$(docker exec "$cont" /usr/local/bin/xray -version 2>/dev/null | head -1 | awk '{print $2}')
    stats=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}' "$cont" 2>/dev/null)
    restarts=$(docker inspect -f '{{.RestartCount}}' "$cont" 2>/dev/null)
    echo "container=$cont version=$ver"
    echo "stats=$stats"
    echo "restarts=$restarts"
    docker logs --tail 500 "$cont" 2>&1 | grep -iE 'error|fail|timeout|refused' | tail -5 || echo "(нет ошибок в логах)"

    summary_kv "Xray" "$cont · v$ver · restarts $restarts"

    RES_STATUS=ok
    RES_SUMMARY="v${ver:-?} · $(echo "$stats" | cut -d'|' -f1) cpu"
    if [ "${restarts:-0}" -gt 5 ]; then
        RES_STATUS=warn
        finding 2 xray "Xray-контейнер рестартил $restarts раз — нестабилен"
    fi
}


# ════════════════════════════════════════════════════════════════════
# ГЛАВНАЯ ЧАСТЬ ДЛЯ QUICK-INSTALL
# ════════════════════════════════════════════════════════════════════

generate_diagnostic_report() {
    # Считаем оценку
    local ok_count=0 warn_count=0 bad_count=0 info_count=0 penalty=0
    while IFS='|' read -r sev tag msg; do
        case "$sev" in
            3) bad_count=$((bad_count+1));   penalty=$((penalty + 3)) ;;
            2) warn_count=$((warn_count+1)); penalty=$((penalty + 1)) ;;
            1) info_count=$((info_count+1)) ;;
        esac
    done < "$FINDINGS_FILE"
    local score=$(( 100 - penalty * 5 ))
    [ "$score" -lt 0 ] && score=0

    echo
    echo -e "${DIM}  ─────────────────────────────────  ИТОГО  ─────────────────────────────────${NC}"
    echo

    if [ -s "$SUMMARY_FILE" ]; then
        echo -e "  ${BOLD}Сводка${NC}"
        while IFS='|' read -r key value; do
            printf "    ${DIM}%-18s${NC} %s\n" "$key" "$value"
        done < "$SUMMARY_FILE"
        echo
    fi
    printf "  Проверки: ${G}%d успешно${NC} · ${Y}%d предупреждений${NC} · ${R}%d ошибок${NC} · ${DIM}%d пропущено${NC}\n\n" \
        "$DIAG_OK" "$DIAG_WARN" "$DIAG_BAD" "$DIAG_SKIP"
    
    # Вердикт
    local verdict_icon="" verdict_color="" verdict_text="" verdict_sub=""
    if [ "$DIAG_OK" -eq 0 ] || [ "$DIAG_SKIP" -ge $(( (CHECK_TOTAL + 1) / 2 )) ]; then
        verdict_icon="?"; verdict_color=$Y
        verdict_text="недостаточно данных"
        verdict_sub="слишком много проверок пропущено; итоговая оценка недостоверна"
    elif [ "$bad_count" = "0" ] && [ "$warn_count" = "0" ] && [ "$DIAG_BAD" -eq 0 ] && [ "$DIAG_WARN" -eq 0 ]; then
        verdict_icon="✓"; verdict_color=$G
        verdict_text="нода в порядке"
        verdict_sub="видео и сервисы должны работать без проблем"
    elif [ "$bad_count" = "0" ]; then
        verdict_icon="⚠"; verdict_color=$Y
        verdict_text="рабочее с замечаниями"
        verdict_sub="проверок с предупреждением: $DIAG_WARN · рекомендаций: $warn_count"
    elif [ "$bad_count" -le 1 ]; then
        verdict_icon="⚠"; verdict_color=$Y
        verdict_text="проблемы есть"
        verdict_sub="$bad_count критичных + $warn_count предупреждений"
    else
        verdict_icon="✗"; verdict_color=$R
        verdict_text="непригодна для видео"
        verdict_sub="$bad_count критичных + $warn_count предупреждений"
    fi
    echo -e "  ${verdict_color}${BOLD}${verdict_icon}  ${verdict_text}${NC} (Score: ${score}/100)"
    echo -e "     ${DIM}${verdict_sub}${NC}"
    echo
    
    # Вывод проблем
    if [ -s "$FINDINGS_FILE" ]; then
        print_findings_group() {
            local sev=$1 title=$2 color=$3 icon=$4
            local count=$(awk -F'|' -v s="$sev" '$1 == s' "$FINDINGS_FILE" | wc -l)
            [ "$count" -eq 0 ] && return
            echo -e "  ${color}${BOLD}▌${NC} ${BOLD}$title${NC} ${DIM}($count)${NC}"
            awk -F'|' -v s="$sev" '$1 == s {print $2 "|" $3}' "$FINDINGS_FILE" | while IFS='|' read -r tag msg; do
                local pad_tag=$(printf '%-12s' "[$tag]")
                echo -e "    ${color}${icon}${NC} ${DIM}${pad_tag}${NC} ${msg}"
            done
            echo
        }
        print_findings_group 3 "Критичные"     "$R" "✗"
        print_findings_group 2 "Предупреждения" "$Y" "⚠"
    fi

    # РЕКОМЕНДАЦИИ QUICK-INSTALL
    local rec_tuning=0 rec_mss=0 rec_hw=0
    while IFS='|' read -r sev tag msg; do
        case "$tag" in
            tcp|conntrack|bufferbloat) rec_tuning=1 ;;
            pmtu|tunnel) rec_mss=1 ;;
            cpu) echo "$msg" | grep -qi softirq && rec_hw=1 ;;
            nic) echo "$msg" | grep -qi drop && rec_hw=1 ;;
        esac
    done < "$FINDINGS_FILE"

    if [ "$rec_tuning" = "1" ] || [ "$rec_mss" = "1" ] || [ "$rec_hw" = "1" ]; then
        echo -e "${CYAN}  ─────────────────────────────────  РЕКОМЕНДАЦИИ  ─────────────────────────────────${NC}"
        echo -e "  ${BOLD}Для устранения проблем перейдите в Главное меню -> Система и Сеть (Пункт 1)${NC} и выполните:"
        [ "$rec_tuning" = "1" ] && echo -e "  ${Y}• Пункт 3: Установка TCP BBR и Тюнинг сети${NC} (Включит алгоритм BBR, fq и расширит буферы/conntrack)"
        [ "$rec_mss" = "1" ]    && echo -e "  ${Y}• Пункт 5: Настройка MSS Clamp${NC} (Исправит зависание картинки из-за фрагментации туннелей)"
        [ "$rec_hw" = "1" ]     && echo -e "  ${Y}• Пункт 6: Аппаратный тюнинг (RPS и Ring Buffers)${NC} (Размажет прерывания по ядрам и увеличит буфер сетевой карты)"
        echo
    fi
}

do_run_diagnostics() {
    local LANG=C.UTF-8
    
    local R G Y B C M BOLD DIM NC CLR_LINE
    if [ -t 1 ]; then
        R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
        B=$'\033[0;34m'; C=$'\033[0;36m'; M=$'\033[0;35m'
        BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
        CLR_LINE=$'\033[K'
    else
        R=""; G=""; Y=""; B=""; C=""; M=""; BOLD=""; DIM=""; NC=""; CLR_LINE=""
    fi

    header "Комплексная диагностика ноды" "Тесты и Бенчмарки"
    
    # Init temp files and traps
    local previous_exit previous_int previous_term
    previous_exit=$(trap -p EXIT)
    previous_int=$(trap -p INT)
    previous_term=$(trap -p TERM)
    LOG=$(mktemp /tmp/node-diagnostic.XXXXXX.log)
    RES_FILE=$(mktemp)
    FINDINGS_FILE=$(mktemp)
    SUMMARY_FILE=$(mktemp)
    if [ -z "$LOG" ] || [ -z "$RES_FILE" ] || [ -z "$FINDINGS_FILE" ] || [ -z "$SUMMARY_FILE" ]; then
        error "Не удалось создать временные файлы диагностики."
        cleanup_diagnostics
        press_enter
        return 1
    fi

    DIAGNOSTICS_INTERRUPTED=0
    DIAG_ACTIVE_PID=""
    CHECK_NUM=0
    CHECK_TOTAL_TIME=0
    CHECK_DONE=0
    ETA_AVG=0
    DIAG_OK=0
    DIAG_WARN=0
    DIAG_BAD=0
    DIAG_SKIP=0

    trap cleanup_diagnostics EXIT
    trap interrupted_diagnostics INT TERM
    
    # 1. Сбор проверок
    DEFAULT_IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
    export DEFAULT_IFACE

    local CHECKS=(
        "Идентификация:check_identify"
        "CPU и нагрузка:check_cpu"
        "Память:check_mem"
        "NIC / интерфейс:check_nic"
        "Туннели:check_tunnel"
        "TCP congestion:check_tcp_cc"
        "TCP tuning:check_tcp_tuning"
        "Conntrack:check_conntrack"
        "DNS-резолв:check_dns"
        "PMTU:check_pmtu"
        "Loss до Google:check_loss"
        "Маршрут (mtr):check_mtr"
        "QUIC / HTTP-3:check_quic"
        "Speed: 1-flow:check_speed_single"
        "Speed: 4-flow:check_speed_4flow"
        "CDN мульти-тест:check_cdn_multi"
        "Сервисы reach:check_services"
        "IP-репутация:check_ip_rep"
        "Bufferbloat:check_bufferbloat"
        "Sustained variance:check_variance"
        "TCP retransmits:check_tcp_stats"
        "IPv6:check_ipv6"
        "Xray:check_xray"
    )

    # 2. Выбор режима
    echo "  Доступны режимы запуска:"
    echo "  1) Быстрый (~1 мин) — без проверки маршрута, 4-flow, CDN, блокировок, bufferbloat и throttling."
    echo "  2) Полный  (~5 мин) — все проверки для глубокого анализа трафика и видео-CDN."
    echo ""
    read -rp "$(printf "${CYAN}Выберите режим (по умолчанию Полный): ${NC}")" mode_choice

    QUICK=0
    if [ "$mode_choice" = "1" ]; then QUICK=1; fi

    local SLOW_CHECKS="check_mtr check_speed_4flow check_cdn_multi check_services check_bufferbloat check_variance"
    
    local EFFECTIVE_CHECKS=()
    for entry in "${CHECKS[@]}"; do
        local fn=${entry##*:}
        if [ "$QUICK" = "1" ] && [[ " $SLOW_CHECKS " == *" $fn "* ]]; then
            continue
        fi
        EFFECTIVE_CHECKS+=("$entry")
    done
    
    CHECK_TOTAL=${#EFFECTIVE_CHECKS[@]}

    # 3. Подготовка и запуск
    echo ""
    echo -ne "  ${DIM}Ставлю недостающие пакеты…${NC}"
    ensure_deps >>"$LOG" 2>&1
    echo -e "
${CLR_LINE}  ${DIM}Лог: $LOG${NC}"
    echo
    
    : > "$FINDINGS_FILE"
    : > "$SUMMARY_FILE"
    
    local DIAG_START=$(date +%s)
    for entry in "${EFFECTIVE_CHECKS[@]}"; do
        local name=${entry%:*}
        local fn=${entry##*:}
        if ! run_check "$name" "$fn"; then
            break
        fi
    done
    local DIAG_DURATION=$(( $(date +%s) - DIAG_START ))
    echo -e "  ${DIM}Прогон занял ${DIAG_DURATION}s${NC}"

    if [ "$DIAGNOSTICS_INTERRUPTED" -eq 1 ]; then
        echo ""
        warn "Диагностика прервана пользователем. Лог сохранён: $LOG"
    else
        # 4. Отчет и рекомендации
        generate_diagnostic_report
    fi

    press_enter
    cleanup_diagnostics
    trap - EXIT INT TERM
    [ -n "$previous_exit" ] && eval "$previous_exit"
    [ -n "$previous_int" ] && eval "$previous_int"
    [ -n "$previous_term" ] && eval "$previous_term"
    [ "$DIAGNOSTICS_INTERRUPTED" -eq 0 ]
}
