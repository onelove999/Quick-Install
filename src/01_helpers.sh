#!/usr/bin/env bash

info()    { printf "${CYAN}[INFO]${NC} %b\n" "$*"; }
success() { printf "${GREEN}[✔]${NC} %b\n" "$*"; }
warn()    { printf "${YELLOW}[⚠]${NC} %b\n" "$*"; }
error()   { printf "${RED}[✘]${NC} %b\n" "$*"; }

menu_section() {
    printf "${BLUE}─── %s " "$1"
    printf '─%.0s' {1..36}
    printf "${NC}\n"
}

menu_item() {
    printf "${BOLD} %2s)${NC} %s\n" "$1" "$2"
}

menu_back() {
    echo ""
    menu_item 0 "← Назад"
    echo ""
}

read_choice() {
    local __var_name=$1 value
    if ! read -r -p "$(printf "${CYAN}Выберите действие: ${NC}")" value; then
        echo ""
        warn "Ввод закрыт. Возврат в предыдущее меню."
        printf -v "$__var_name" '%s' "0"
        return 1
    fi
    printf -v "$__var_name" '%s' "$value"
}

confirm_action() {
    local prompt=$1 answer
    if ! read -r -p "$(printf "${YELLOW}%s [y/N]: ${NC}" "$prompt")" answer; then
        return 1
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

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
    if ! command -v ufw &>/dev/null; then
        printf "${RED}(Не установлен)${NC}"
        return
    fi
    if ufw status | grep -q "Status: active"; then
        printf "${GREEN}(Активен)${NC}"
    else
        printf "${RED}(Выключен)${NC}"
    fi
}

is_valid_ip() {
    local ip=$1 octet
    local -a octets
    IFS=. read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

is_valid_port() {
    local port=$1 value
    [[ $port =~ ^[0-9]+$ ]] || return 1
    [ "${#port}" -le 5 ] || return 1
    value=$((10#$port))
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

is_valid_port_spec() {
    local spec=$1 first last
    if [[ "$spec" == *:* ]]; then
        first=${spec%%:*}
        last=${spec##*:}
        [ "$first" != "$last" ] && is_valid_port "$first" && is_valid_port "$last" && [ "$((10#$first))" -le "$((10#$last))" ]
    else
        is_valid_port "$spec"
    fi
}

is_valid_protocol() {
    case "$1" in
        tcp|udp|any) return 0 ;;
        *) return 1 ;;
    esac
}

require_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        error "Не найдены необходимые команды: ${missing[*]}"
        return 1
    fi
}

measure_time() {
    local start end rc
    start=$(date +%s)
    "$@"
    rc=$?
    end=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        info "Выполнено за $((end - start)) сек."
    else
        error "Команда завершилась с кодом $rc за $((end - start)) сек."
    fi
    return "$rc"
}

run_step() {
    local label=$1
    shift
    info "$label"
    measure_time "$@"
}

download_atomic() {
    local url=$1 destination=$2 tmp_file
    mkdir -p "$(dirname "$destination")" || return 1
    tmp_file=$(mktemp "${destination}.tmp.XXXXXX") || return 1

    if command -v curl &>/dev/null; then
        curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 "$url" -o "$tmp_file"
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp_file" "$url"
    else
        error "Для загрузки требуется curl или wget."
        rm -f "$tmp_file"
        return 1
    fi

    if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        return 1
    fi
    mv -f "$tmp_file" "$destination"
}

run_remote_script() {
    local url=$1
    shift
    local script_file rc
    script_file=$(mktemp /tmp/qi-script.XXXXXX) || return 1
    if ! download_atomic "$url" "$script_file"; then
        error "Не удалось скачать $url"
        rm -f "$script_file"
        return 1
    fi
    chmod 700 "$script_file"
    bash "$script_file" "$@"
    rc=$?
    rm -f "$script_file"
    return "$rc"
}

compose_run() {
    local project_dir=$1
    shift
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        (cd "$project_dir" && docker compose "$@")
    elif command -v docker-compose &>/dev/null; then
        (cd "$project_dir" && docker-compose "$@")
    else
        error "Docker Compose не установлен."
        return 1
    fi
}

compose_validate() {
    compose_run "$1" config --quiet
}

ensure_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        return 0
    fi
    require_commands curl || return 1
    warn "Docker не найден. Будет запущен официальный установщик get.docker.com."
    confirm_action "Установить Docker" || return 1
    run_remote_script "https://get.docker.com" || return 1
    command -v docker &>/dev/null && docker compose version &>/dev/null
}

get_sshd_ports() {
    local ports=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        ports=$(awk '{print $4}' <<< "$SSH_CONNECTION")
    fi
    if [ -z "$ports" ] && command -v sshd &>/dev/null; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un)
    fi
    if [ -z "$ports" ] && [ -r /etc/ssh/sshd_config ]; then
        ports=$(awk 'tolower($1) == "port" {print $2}' /etc/ssh/sshd_config | sort -un)
    fi
    printf '%s\n' "${ports:-22}"
}

show_system_info() {
    local os ram_total ram_used load
    os=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    # Получаем IP локально из системы (быстрее и надежнее чем curl)
    if [ -z "${_CACHED_IP:-}" ]; then
        _CACHED_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')
    fi
    ram_total=$(free -h | awk '/Mem:/ {print $2}')
    ram_used=$(free -h | awk '/Mem:/ {print $3}')
    load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    
    printf "${BLUE}─── Информация о сервере ───────────────────────────${NC}\n"
    printf "  OS:   %-20s | IP:   ${CYAN}%s${NC}\n" "$os" "$_CACHED_IP"
    printf "  RAM:  %-20s | Load: %s\n" "$ram_used / $ram_total" "$load"
    printf "  BBR:  %-20s | IPv6: %s\n" "$(get_bbr_status)" "$(get_ipv6_status)"
    printf "${BLUE}─────────────────────────────────────────────────────${NC}\n"
}

press_enter() {
    echo ""
    if [ -t 0 ]; then
        read -r -p "$(printf "${YELLOW}Нажмите Enter для продолжения...${NC}")" _ || true
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Требуются права root. Запустите: sudo qi"
        exit 1
    fi
}
