#!/usr/bin/env bash

info()    { printf "${CYAN}[INFO]${NC} %b\n" "$*"; }
success() { printf "${GREEN}[✔]${NC} %b\n" "$*"; }
warn()    { printf "${YELLOW}[⚠]${NC} %b\n" "$*"; }
error()   { printf "${RED}[✘]${NC} %b\n" "$*"; }

header() {
    local title="$1"
    local parent="$2"
    echo ""
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    if [ -n "$parent" ]; then
        printf "  ${MAGENTA}%s${NC} > ${BOLD}%s${NC}\n" "$parent" "$title"
    else
        printf "  ${BOLD}%s${NC}\n" "$title"
    fi
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

get_docker_status() {
    local name="$1"
    if ! command -v docker &>/dev/null; then
        printf "${RED}(Docker не установлен)${NC}"
        return
    fi
    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        printf "${GREEN}(Запущен)${NC}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        printf "${YELLOW}(Остановлен)${NC}"
    else
        printf "${RED}(Не установлен)${NC}"
    fi
}

get_bbr_status() {
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        printf "${GREEN}(Активен)${NC}"
    else
        printf "${RED}(Выключен)${NC}"
    fi
}

get_ipv6_status() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "0" ]; then
        printf "${GREEN}(Включен)${NC}"
    else
        printf "${RED}(Выключен)${NC}"
    fi
}

get_ufw_status() {
    if ufw status | grep -q "Status: active"; then
        printf "${GREEN}(Активен)${NC}"
    else
        printf "${RED}(Выключен)${NC}"
    fi
}

is_valid_ip() {
    local ip=$1
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

is_valid_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

measure_time() {
    local start=$(date +%s)
    "$@"
    local end=$(date +%s)
    info "Выполнено за $((end - start)) сек."
}

show_system_info() {
    local os=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    local ip=$(curl -s4 ifconfig.me || echo "N/A")
    local ram_total=$(free -h | awk '/Mem:/ {print $2}')
    local ram_used=$(free -h | awk '/Mem:/ {print $3}')
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    
    printf "${BLUE}─── Информация о сервере ───────────────────────────${NC}\n"
    printf "  OS:   %-20s | IP:   ${CYAN}%s${NC}\n" "$os" "$ip"
    printf "  RAM:  %-20s | Load: %s\n" "$ram_used / $ram_total" "$load"
    printf "  BBR:  %-20s | IPv6: %s\n" "$(get_bbr_status)" "$(get_ipv6_status)"
    printf "${BLUE}─────────────────────────────────────────────────────${NC}\n"
}

press_enter() {
    echo ""
    read -rp "$(printf "${YELLOW}Нажмите Enter для продолжения...${NC}")" _
}

