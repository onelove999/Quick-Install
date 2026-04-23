#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# VPN GUARD — Хелперы
# ═══════════════════════════════════════════════════════════════

VPNGUARD_REPO_URL="https://github.com/onelove999/vpnguard.git"

compose_vpnguard() {
    docker compose -f "${VPNGUARD_DIR}/docker-compose.yml" "$@"
}

vpnguard_get_value() {
    local key="$1"
    grep "^${key}:" "$VPNGUARD_CONFIG" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/^"//;s/"$//'
}

vpnguard_mask_token() {
    local token="$1"
    if [ ${#token} -gt 10 ]; then
        echo "${token:0:5}...${token: -4}"
    else
        echo "$token"
    fi
}

vpnguard_update_config_value() {
    local key="$1"
    local value="$2"
    sed -i "s|^${key}:.*|${key}: ${value}|" "$VPNGUARD_CONFIG"
}

ensure_vpnguard_source_settings() {
    if ! command -v git &>/dev/null; then
        info "Установка git..."
        apt-get update -qq && apt-get install -y git -qq
    fi
    return 0
}

download_vpnguard_source() {
    local src_dir="${VPNGUARD_DIR}/src"
    if [ -d "${src_dir}/.git" ]; then
        info "Обновление исходников VPN Guard..."
        cd "$src_dir" && git pull
    else
        info "Клонирование VPN Guard..."
        mkdir -p "$VPNGUARD_DIR"
        git clone "$VPNGUARD_REPO_URL" "$src_dir"
    fi
}

generate_vpnguard_config() {
    if [ -f "$VPNGUARD_CONFIG" ]; then
        warn "Конфиг уже существует: $VPNGUARD_CONFIG"
        read -rp "$(printf "${YELLOW}Перезаписать? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Используем существующий конфиг."
            return 0
        fi
    fi

    read -rp "$(printf "${CYAN}Имя ноды: ${NC}")" node_name
    read -rp "$(printf "${CYAN}Telegram Bot Token: ${NC}")" bot_token
    read -rp "$(printf "${CYAN}Telegram Chat ID: ${NC}")" chat_id

    if [ -z "$node_name" ] || [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        error "Все поля обязательны!"
        return 1
    fi

    mkdir -p "$(dirname "$VPNGUARD_CONFIG")"
    cat > "$VPNGUARD_CONFIG" <<EOF
node_name: "${node_name}"
log_file: "/var/log/remnanode/access.log"
telegram:
  bot_token: "${bot_token}"
  chat_id: "${chat_id}"
scoring:
  threshold: 800
  alert_cooldown: 120
EOF
    success "Конфиг создан: $VPNGUARD_CONFIG"
    return 0
}

generate_vpnguard_compose() {
    local compose_file="${VPNGUARD_DIR}/docker-compose.yml"
    info "Генерация docker-compose.yml..."
    cat > "$compose_file" <<EOF
services:
  vpnguard:
    build: ./src
    container_name: vpnguard
    restart: unless-stopped
    volumes:
      - ./config:/app/config:ro
      - /var/log/remnanode:/var/log/remnanode:ro
      - ./reports:/app/reports
EOF
    success "docker-compose.yml создан."
}

# ═══════════════════════════════════════════════════════════════
# VPN GUARD — Управление
# ═══════════════════════════════════════════════════════════════

do_install_vpnguard() {
    header "Установка / Обновление VPN Guard" "Мониторинг"

    if ! command -v curl &>/dev/null; then
        info "Устанавливаю curl..."
        apt-get update -qq
        apt-get install -y curl tar > /dev/null 2>&1
    fi

    if ! command -v docker &>/dev/null; then
        info "Устанавливаю Docker..."
        measure_time curl -fsSL https://get.docker.com | sh
        success "Docker установлен."
    fi

    if ! ensure_vpnguard_source_settings; then
        press_enter
        return
    fi

    if ! download_vpnguard_source; then
        press_enter
        return
    fi

    if ! generate_vpnguard_config; then
        press_enter
        return
    fi

    generate_vpnguard_compose

    info "Собираю и запускаю VPN Guard..."
    if ! measure_time compose_vpnguard build --pull; then
        error "Сборка контейнера завершилась ошибкой."
        press_enter
        return
    fi

    if ! compose_vpnguard up -d; then
        error "Не удалось запустить контейнер VPN Guard."
        press_enter
        return
    fi

    success "VPN Guard установлен и запущен."
    press_enter
}

do_start_vpnguard() {
    header "Запуск VPN Guard" "Мониторинг"
    compose_vpnguard up -d
    press_enter
}

do_stop_vpnguard() {
    header "Остановка VPN Guard" "Мониторинг"
    compose_vpnguard stop
    press_enter
}

do_restart_vpnguard() {
    header "Перезапуск VPN Guard" "Мониторинг"
    compose_vpnguard restart
    press_enter
}

do_logs_vpnguard() {
    header "Логи VPN Guard" "Мониторинг > VPN Guard"
    info "Выход: Ctrl+C"
    echo ""
    compose_vpnguard logs --tail=200 -f
}

do_interactive_vpnguard() {
    header "Интерактивная фильтрация" "VPN Guard"
    info "Для сохранения результата используйте путь внутри /reports"
    compose_vpnguard run --rm vpnguard --interactive
}

do_report_vpnguard() {
    header "Сводный отчет" "VPN Guard"
    info "Генерация отчета..."
    compose_vpnguard run --rm vpnguard --report
    press_enter
}

do_vpnguard_settings() {
    if [ ! -f "$VPNGUARD_CONFIG" ]; then
        error "Сначала установите VPN Guard."
        press_enter
        return
    fi

    while true; do
        clear
        header "Настройки VPN Guard" "Мониторинг > VPN Guard"

        local node_name bot_token chat_id threshold cooldown status_line
        node_name="$(vpnguard_get_value "node_name")"
        bot_token="$(vpnguard_get_value "  bot_token")"
        chat_id="$(vpnguard_get_value "  chat_id")"
        threshold="$(vpnguard_get_value "  threshold")"
        cooldown="$(vpnguard_get_value "  alert_cooldown")"
        
        status_line="$(get_docker_status "vpnguard")"

        printf "${BLUE}─── Текущая конфигурация ────────── ${status_line} ──${NC}\n"
        printf "  • Имя ноды:    ${BOLD}%s${NC}\n" "${node_name}"
        printf "  • Бот Токен:   ${BOLD}%s${NC}\n" "$(vpnguard_mask_token "$bot_token")"
        printf "  • Chat ID:     ${BOLD}%s${NC}\n" "${chat_id:-"(не задан)"}"
        printf "  • Порог/Кулдаун:  ${BOLD}%s баллов / %s сек.${NC}\n" "${threshold}" "${cooldown}"
        printf "${BLUE}─────────────────────────────────────────────────────${NC}\n"
        echo ""
        printf "${BOLD}  1)${NC} Изменить Telegram Bot Token\n"
        printf "${BOLD}  2)${NC} Изменить Telegram Chat ID\n"
        printf "${BOLD}  3)${NC} Изменить имя ноды\n"
        printf "${BOLD}  4)${NC} Изменить порог баллов\n"
        printf "${BOLD}  5)${NC} Изменить кулдаун алерта\n"
        echo ""
        printf "${BOLD}  6)${NC} Редактировать конфиг вручную (nano)\n"
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""

        read -rp "$(printf "${CYAN}Выберите настройку: ${NC}")" choice
        case "$choice" in
            1)
                read -rp "$(printf "${CYAN}Новый Telegram Bot Token: ${NC}")" value
                vpnguard_update_config_value "  bot_token" "\"${value}\""
                compose_vpnguard restart
                ;;
            2)
                read -rp "$(printf "${CYAN}Новый Telegram Chat ID: ${NC}")" value
                vpnguard_update_config_value "  chat_id" "\"${value}\""
                compose_vpnguard restart
                ;;
            3)
                read -rp "$(printf "${CYAN}Новое имя ноды: ${NC}")" value
                vpnguard_update_config_value "node_name" "\"${value}\""
                compose_vpnguard restart
                ;;
            4)
                read -rp "$(printf "${CYAN}Новый порог баллов: ${NC}")" value
                vpnguard_update_config_value "  threshold" "${value}"
                compose_vpnguard restart
                ;;
            5)
                read -rp "$(printf "${CYAN}Новый кулдаун (сек): ${NC}")" value
                vpnguard_update_config_value "  alert_cooldown" "${value}"
                compose_vpnguard restart
                ;;
            6)
                nano "$VPNGUARD_CONFIG"
                compose_vpnguard restart
                ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

menu_vpnguard() {
    while true; do
        clear
        header "VPN Guard" "Мониторинг"
        printf "${BLUE}─── Управление ─────────────── $(get_docker_status "vpnguard") ───${NC}\n"
        printf "${BOLD}  1)${NC} Установить / Обновить VPN Guard\n"
        printf "${BOLD}  2)${NC} Запустить\n"
        printf "${BOLD}  3)${NC} Остановить\n"
        printf "${BOLD}  4)${NC} Перезапустить\n"
        echo ""
        printf "${BLUE}─── Аналитика и Логи ───────────────────────────────${NC}\n"
        printf "${BOLD}  5)${NC} Показать логи контейнера\n"
        printf "${BOLD}  6)${NC} Интерактивная фильтрация\n"
        printf "${BOLD}  7)${NC} Сводный отчет\n"
        echo ""
        printf "${BOLD}  8)${NC} Настройки VPN Guard\n"
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_vpnguard ;;
            2) do_start_vpnguard ;;
            3) do_stop_vpnguard ;;
            4) do_restart_vpnguard ;;
            5) do_logs_vpnguard ;;
            6) do_interactive_vpnguard ;;
            7) do_report_vpnguard ;;
            8) do_vpnguard_settings ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}


do_install_beszel() {
    header "Установка Beszel Agent" "Мониторинг"

    # 1. Docker
    if ! command -v docker &>/dev/null; then
        info "Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        success "Docker установлен."
    fi

    # 2. Создание папки
    local BESZEL_DIR="/opt/beszel"
    mkdir -p "$BESZEL_DIR"
    cd "$BESZEL_DIR" || return
    info "Папка $BESZEL_DIR создана."

    # 0. Проверка запущенного контейнера
    if docker ps --format '{{.Names}}' | grep -q "^beszel-agent$"; then
        warn "Контейнер 'beszel-agent' уже запущен!"
        read -rp "$(printf "${YELLOW}Вы уверены, что хотите переустановить Beszel Agent? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    fi

    # 3. Настройка docker-compose.yml
    if [ -f "docker-compose.yml" ]; then
        warn "Файл docker-compose.yml уже существует в $BESZEL_DIR."
        read -rp "$(printf "${YELLOW}Перезаписать/Редактировать его? [y/N]: ${NC}")" overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            info "Изменения отменены."
            press_enter
            return
        fi
    fi
    info "Сейчас откроется nano для создания docker-compose.yml"
    info "Вставьте ваш конфиг (с KEY) и сохраните (Ctrl+O, Enter, Ctrl+X)"
    sleep 2
    nano docker-compose.yml

    if [ ! -s docker-compose.yml ]; then
        warn "docker-compose.yml пуст. Установка прервана."
        press_enter
        return
    fi

    # 4. Настройка UFW
    echo ""
    read -rp "$(printf "${CYAN}Введите IP-адрес Beszel Hub для доступа к порту 45876: ${NC}")" hub_ip
    if [ -n "$hub_ip" ]; then
        info "Разрешаем доступ к порту 45876 для $hub_ip..."
        ufw allow from "$hub_ip" to any port 45876 proto tcp
        success "Доступ разрешен."
    else
        warn "IP не введен. Порт 45876 не открыт автоматически."
    fi

    # 5. Запуск
    info "Запуск контейнера Beszel Agent..."
    docker compose up -d
    success "Beszel Agent запущен."
    press_enter
}

do_uninstall_warp() {
    header "Удаление Cloudflare WARP" "Сервисы"
    read -rp "$(printf "${YELLOW}Удалить WARP полностью? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi
    systemctl stop wg-quick@warp 2>/dev/null || true
    systemctl disable wg-quick@warp 2>/dev/null || true
    rm -f /etc/wireguard/warp.conf /etc/wireguard/wgcf-account.toml
    rm -f /usr/local/bin/wgcf
    rm -f wgcf-profile.conf wgcf-account.toml 2>/dev/null
    success "WARP удалён."
    press_enter
}

do_install_warp() {
    header "Установка Cloudflare WARP" "Сервисы"

    # 1. Проверка установки
    if command -v wgcf >/dev/null 2>&1 && [ -f "/etc/wireguard/warp.conf" ]; then
        warn "WARP уже установлен."
        read -rp "$(printf "${YELLOW}Переустановить? [y/N]: ${NC}")" reinst
        if [[ ! "$reinst" =~ ^[Yy]$ ]]; then return; fi
        do_uninstall_warp
    fi

    # 2. Установка WireGuard
    info "Установка WireGuard..."
    measure_time bash -c "apt-get update -qq && apt-get install -y wireguard wget curl jq"
    
    # 3. Скачивание wgcf
    info "Скачивание wgcf..."
    local ARCH WGCF_ARCH WGCF_RELEASE_URL WGCF_VERSION WGCF_DOWNLOAD_URL
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        *) WGCF_ARCH="amd64" ;;
    esac
    
    WGCF_RELEASE_URL="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    WGCF_VERSION=$(curl -s "$WGCF_RELEASE_URL" | jq -r .tag_name)
    WGCF_DOWNLOAD_URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}"
    
    wget -q "$WGCF_DOWNLOAD_URL" -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    success "wgcf установлен."

    # 4. Регистрация и генерация
    info "Регистрация аккаунта WARP..."
    yes | wgcf register
    wgcf generate
    
    if [ ! -f "wgcf-profile.conf" ]; then
        error "Не удалось сгенерировать конфиг wgcf-profile.conf"
        press_enter
        return
    fi

    # 5. Оптимизация конфига для сервера
    info "Настройка конфигурации (Table = off)..."
    # Удаляем DNS из конфига, чтобы не сломать системный резолвер
    sed -i '/^DNS =/d' "wgcf-profile.conf"
    # Добавляем Table = off, чтобы не перехватывать ВЕСЬ трафик (опасно для SSH)
    if ! grep -q "Table = off" "wgcf-profile.conf"; then
        sed -i '/^MTU =/a Table = off' "wgcf-profile.conf"
    fi
    # Добавляем Keepalive
    if ! grep -q "PersistentKeepalive" "wgcf-profile.conf"; then
        sed -i '/^Endpoint =/a PersistentKeepalive = 25' "wgcf-profile.conf"
    fi

    # 6. IPv6 Check
    if ! (sysctl net.ipv6.conf.all.disable_ipv6 | grep -q ' = 0'); then
        info "IPv6 отключен в системе, удаляем его из конфига WARP..."
        sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "wgcf-profile.conf"
        sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "wgcf-profile.conf"
    fi

    # 7. Установка конфига
    mkdir -p /etc/wireguard
    mv "wgcf-profile.conf" /etc/wireguard/warp.conf
    mv "wgcf-account.toml" /etc/wireguard/wgcf-account.toml 2>/dev/null || true
    
    # 8. Запуск
    info "Запуск интерфейса warp..."
    systemctl enable wg-quick@warp
    systemctl start wg-quick@warp
    
    # 9. Проверка
    info "Проверка статуса..."
    sleep 3
    if wg show warp &>/dev/null; then
        success "WARP успешно запущен!"
        curl -s --interface warp https://www.cloudflare.com/cdn-cgi/trace | grep "warp="
    else
        error "Ошибка запуска интерфейса warp."
    fi
    
    press_enter
}

menu_warp() {
    while true; do
        clear
        header "Cloudflare WARP" "Приложения"
        printf "${BOLD}  1)${NC} Установить WARP\n"
        printf "${BOLD}  2)${NC} Удалить WARP\n"
        printf "${BOLD}  3)${NC} Показать статус (wg show)\n"
        printf "${BOLD}  4)${NC} Перезапустить WARP\n"
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_warp ;;
            2) do_uninstall_warp ;;
            3) header "Статус WireGuard"; wg show warp; press_enter ;;
            4) systemctl restart wg-quick@warp; success "Перезапущено"; sleep 1 ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

do_install_adguard() {
    header "Установка AdGuard Home" "Сервисы"

    # 0. Проверка существующей установки
    if [ -d "$AGH_DIR" ] || (command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q "^adguardhome$"); then
        warn "AdGuard Home уже установлен или обнаружена папка установки."
        read -rp "$(printf "${YELLOW}Вы уверены, что хотите переустановить AdGuard Home? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    else
        read -rp "$(printf "${YELLOW}Установить AdGuard Home? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    fi

    # 1. Подготовка папок
    info "Создание директорий: ${AGH_DIR}/workdir, ${AGH_DIR}/confdir..."
    mkdir -p "${AGH_DIR}/workdir" "${AGH_DIR}/confdir"
    
    # 2. Создание docker-compose.yml
    info "Создание docker-compose.yml..."
    cat > "${AGH_DIR}/docker-compose.yml" <<EOF
services:
  adguardhome:
    image: adguard/adguardhome
    container_name: adguardhome
    restart: unless-stopped
    ports:
      # DNS выводим в сеть Docker (чтобы Xray его увидел)
      - "172.17.0.1:5353:53/tcp"
      - "172.17.0.1:5353:53/udp"
      # Порт для мастера первоначальной настройки (скрыт от интернета)
      - "127.0.0.1:3000:3000/tcp"
      # Порт для самой веб-панели (скрыт от интернета)
      - "127.0.0.1:8080:80/tcp"
    volumes:
      - ./workdir:/opt/adguardhome/work
      - ./confdir:/opt/adguardhome/conf
EOF

    # 3. Редактирование AdGuardHome.yaml
    info "Сейчас откроется nano для редактирования AdGuardHome.yaml"
    info "Вставьте ваш конфиг и сохраните (Ctrl+O, Enter, Ctrl+X)"
    sleep 2
    nano "${AGH_DIR}/confdir/AdGuardHome.yaml"

    # 4. Запуск
    info "Запуск контейнера..."
    cd "${AGH_DIR}" && docker compose up -d
    
    success "AdGuard Home установлен и запущен."
    press_enter
}

do_start_adguard() {
    header "Запуск AdGuard Home"
    cd "${AGH_DIR}" && docker compose up -d
    success "Выполнено."
    press_enter
}

do_stop_adguard() {
    header "Остановка AdGuard Home"
    cd "${AGH_DIR}" && docker compose stop
    success "Выполнено."
    press_enter
}

do_restart_adguard() {
    header "Перезапуск AdGuard Home"
    cd "${AGH_DIR}" && docker compose restart
    success "Выполнено."
    press_enter
}

do_logs_adguard() {
    header "Логи AdGuard Home"
    cd "${AGH_DIR}" && docker compose logs -f --tail=100
}

do_edit_adguard_yaml() {
    header "Редактирование AdGuardHome.yaml"
    if [ -f "${AGH_DIR}/confdir/AdGuardHome.yaml" ]; then
        nano "${AGH_DIR}/confdir/AdGuardHome.yaml"
        success "Редактирование завершено."
    else
        error "Файл конфигурации не найден!"
    fi
    press_enter
}

do_overwrite_adguard_yaml() {
    header "Перезапись AdGuardHome.yaml"
    warn "Это действие полностью ОЧИСТИТ текущий конфиг!"
    read -rp "$(printf "${YELLOW}Вы уверены, что хотите продолжить? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

    local yaml_path="${AGH_DIR}/confdir/AdGuardHome.yaml"
    
    # Очищаем файл
    : > "$yaml_path"
    info "Файл очищен. Сейчас откроется nano..."
    sleep 1
    nano "$yaml_path"
    
    info "Перезапуск контейнера для применения нового конфига..."
    cd "${AGH_DIR}" && docker compose restart
    
    success "Конфигурация обновлена и AdGuard Home перезапущен."
    press_enter
}

menu_adguard() {
    while true; do
        clear
        header "AdGuard Home" "Приложения"
        printf "${BLUE}─── Состояние: $(get_docker_status "adguardhome") ────────────${NC}\n"
        printf "${BOLD}  1)${NC} Установить AdGuard Home (с нуля)\n"
        printf "${BOLD}  2)${NC} Запустить\n"
        printf "${BOLD}  3)${NC} Остановить\n"
        printf "${BOLD}  4)${NC} Перезапустить\n"
        printf "${BOLD}  5)${NC} Показать логи\n"
        printf "${BOLD}  6)${NC} Редактировать AdGuardHome.yaml\n"
        printf "${BOLD}  7)${NC} ПЕРЕЗАПИСАТЬ AdGuardHome.yaml (Очистить)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_adguard ;;
            2) do_start_adguard ;;
            3) do_stop_adguard ;;
            4) do_restart_adguard ;;
            5) do_logs_adguard ;;
            6) do_edit_adguard_yaml ;;
            7) do_overwrite_adguard_yaml ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

do_trafficguard() {
    header "Trafficguard Pro Manager"
    if command -v rknpidor &>/dev/null; then
        rknpidor
    else
        warn "Команда rknpidor не найдена."
        read -rp "$(printf "${YELLOW}Хотите установить Trafficguard Pro? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка Trafficguard Pro..."
            curl -fsSL https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh | bash
            success "Установка завершена."
            if command -v rknpidor &>/dev/null; then
                rknpidor
            fi
        else
            info "Установка отменена."
        fi
    fi
    press_enter
}

menu_security() {
    while true; do
        clear
        header "Безопасность" "Главное меню"
        printf "${BOLD}  1)${NC} Настройка Фаервола (UFW)\n"
        printf "${BOLD}  2)${NC} Trafficguard Pro Manager\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) menu_ufw ;;
            2) do_trafficguard ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

do_install_logs() {
    header "Установка системы логов"

    # 0. Проверка существующей установки
    if [ -f "/etc/logrotate.d/remnanode" ] || [ -d "$LOG_DIR" ]; then
        warn "Система логов 'remnanode' уже настроена."
        read -rp "$(printf "${YELLOW}Вы уверены, что хотите переустановить систему логов? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    else
        read -rp "$(printf "${YELLOW}Установить систему логов (logrotate + папки)? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    fi

    # 1. Logrotate
    if ! command -v logrotate &>/dev/null; then
        info "Установка logrotate..."
        apt-get update -qq && apt-get install -y logrotate
    fi

    # 2. Папки и файлы
    mkdir -p "$LOG_DIR"
    touch "$LOG_DIR/access.log"
    touch "$LOG_DIR/error.log"
    chmod -R 777 "$LOG_DIR"
    info "Папка $LOG_DIR готова."

    # 3. Logrotate конфиг
    cat <<EOF > /etc/logrotate.d/remnanode
$LOG_DIR/*.log {
    su root root
    daily
    rotate 3
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

menu_monitoring() {
    while true; do
        clear
        header "Мониторинг" "Главное меню"
        printf "${BOLD}  1)${NC} Beszel Agent (Панель мониторинга)\n"
        printf "${BOLD}  2)${NC} VPN Guard (Docker + Аналитика)\n"
        printf "${BOLD}  3)${NC} Настройка ротации логов (Logrotate)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_beszel ;;
            2) menu_vpnguard ;;
            3) do_install_logs ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

menu_apps() {
    while true; do
        clear
        header "Сервисы" "Главное меню"
        printf "${BOLD}  1)${NC} AdGuard Home (DNS-фильтрация)\n"
        printf "${BOLD}  2)${NC} Cloudflare WARP (VPN для сервера)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) menu_adguard ;;
            2) menu_warp ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
# 6. ТЕСТЫ И БЕНЧМАРКИ (ДОПОЛНИТЕЛЬНО)
# ═══════════════════════════════════════════════════════════════

do_test_ip_region() {
    header "Проверка региона IP" "Тесты"
    info "Запрос данных от ip-api.com..."
    echo ""
    curl -s http://ip-api.com/json/ | jq . 2>/dev/null || curl -s http://ip-api.com/json/
    echo ""
    press_enter
}

do_test_censor_geoblock() {
    header "Censorcheck: Геоблокировка" "Тесты"
    info "Запуск скрипта censorcheck..."
    curl -sL https://raw.githubusercontent.com/censorcheck/censorcheck/main/censorcheck.sh | bash -s -- --geo
    press_enter
}

do_test_censor_dpi() {
    header "Censorcheck: Проверка DPI" "Тесты"
    info "Запуск полной проверки..."
    curl -sL https://raw.githubusercontent.com/censorcheck/censorcheck/main/censorcheck.sh | bash
    press_enter
}

do_test_ip_quality_place() {
    header "IP.Check.Place" "Тесты"
    info "Запуск скрипта от Check.Place..."
    curl -L https://raw.githubusercontent.com/everStarry/IP.Check.Place/main/check.sh | bash
    press_enter
}

do_test_ip_quality_check() {
    header "IPQuality Index" "Тесты"
    bash <(curl -Ls IP.Check.Place)
    press_enter
}

do_test_iperf_ru() {
    header "RU iPerf3 Speedtest" "Тесты"
    info "Тестирование скорости до российских серверов..."
    curl -sL https://raw.githubusercontent.com/m-on-key/iperfall/main/iperfall.sh | bash
    press_enter
}

do_test_yabs() {
    header "YABS (Yet Another Bench Script)" "Тесты"
    info "Запуск полного бенчмарка (это может занять 5-10 минут)..."
    curl -sL yabs.sh | bash
    press_enter
}

do_test_bench_sh() {
    header "Bench.sh" "Тесты"
    info "Запуск классического теста..."
    wget -qO- bench.sh | bash
    press_enter
}

do_test_cpu_sysbench() {
    header "CPU Benchmark (sysbench)" "Тесты"
    if ! command -v sysbench &>/dev/null; then
        info "Установка sysbench..."
        apt-get update -qq && apt-get install -y sysbench > /dev/null
    fi
    info "Запуск теста (1 минута)..."
    sysbench cpu --cpu-max-prime=20000 run
    press_enter
}

menu_tests() {
    while true; do
        clear
        header "Тесты и Бенчмарки" "Главное меню"
        printf "${BLUE}─── Проверка IP и Блокировок ────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} Проверка региона IP\n"
        printf "${BOLD}  2)${NC} Censorcheck: Проверка геоблока\n"
        printf "${BOLD}  3)${NC} Censorcheck: Проверка DPI (РФ)\n"
        printf "${BOLD}  4)${NC} IP.Check.Place (Full info)\n"
        printf "${BOLD}  5)${NC} IPQuality (Score check)\n"
        echo ""
        printf "${BLUE}─── Скорость и Производительность ───────────────────${NC}\n"
        printf "${BOLD}  6)${NC} Скорость до RU iPerf3 серверов\n"
        printf "${BOLD}  7)${NC} YABS (CPU + Disk + Net IPv4)\n"
        printf "${BOLD}  8)${NC} Bench.sh (Info + IPv4/IPv6 Speed)\n"
        printf "${BOLD}  9)${NC} Тест CPU (через sysbench)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_test_ip_region ;;
            2) do_test_censor_geoblock ;;
            3) do_test_censor_dpi ;;
            4) do_test_ip_quality_place ;;
            5) do_test_ip_quality_check ;;
            6) do_test_iperf_ru ;;
            7) do_test_yabs ;;
            8) do_test_bench_sh ;;
            9) do_test_cpu_sysbench ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

