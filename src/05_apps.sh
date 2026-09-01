#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# VPN GUARD — Хелперы
# ═══════════════════════════════════════════════════════════════

VPNGUARD_GITHUB_REPO="onelove999/Quick-Install"
VPNGUARD_GITHUB_REF="main"

compose_vpnguard() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        (cd "$VPNGUARD_DIR" && docker compose "$@")
        return $?
    fi

    if command -v docker-compose &>/dev/null; then
        (cd "$VPNGUARD_DIR" && docker-compose "$@")
        return $?
    fi

    error "Docker Compose не найден."
    return 1
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
    mkdir -p "$VPNGUARD_DIR"
    info "Источник VPN Guard: ${VPNGUARD_GITHUB_REPO}@${VPNGUARD_GITHUB_REF}"
}

download_vpnguard_source() {
    local repo="${VPNGUARD_GITHUB_REPO}"
    local ref="${VPNGUARD_GITHUB_REF}"
    local archive_url="https://github.com/${repo}/archive/${ref}.tar.gz"
    local tmp_dir archive_file root_dir

    if [ -z "$repo" ]; then
        error "GitHub репозиторий не задан."
        return 1
    fi

    tmp_dir="$(mktemp -d)"
    archive_file="${tmp_dir}/vpnguard.tar.gz"

    info "Скачиваю исходники VPN Guard из ${repo}@${ref}..."
    if ! curl -fsSL "$archive_url" -o "$archive_file"; then
        rm -rf "$tmp_dir"
        error "Не удалось скачать архив ${archive_url}"
        return 1
    fi

    if ! tar -xzf "$archive_file" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        error "Не удалось распаковать архив."
        return 1
    fi

    root_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ ! -d "${root_dir}/vpnguard" ]; then
        rm -rf "$tmp_dir"
        error "В архиве не найден каталог vpnguard/."
        return 1
    fi

    mkdir -p "${VPNGUARD_DIR}/src"
    rm -rf "${VPNGUARD_DIR}/src/vpnguard"
    cp -a "${root_dir}/vpnguard" "${VPNGUARD_DIR}/src/vpnguard"
    rm -rf "$tmp_dir"

    success "Исходники VPN Guard обновлены."
}

generate_vpnguard_config() {
    mkdir -p "$VPNGUARD_DIR" "${VPNGUARD_DIR}/reports"
    touch "${VPNGUARD_DIR}/guard_alerts.log"

    local default_node_name
    default_node_name="$(hostname)"

    if [ -f "$VPNGUARD_CONFIG" ]; then
        info "Конфиг VPN Guard уже существует: $VPNGUARD_CONFIG"
        return 0
    fi

    read -rp "$(printf "${CYAN}Имя ноды [${default_node_name}]: ${NC}")" node_name
    node_name="${node_name:-$default_node_name}"
    read -rp "$(printf "${CYAN}Telegram Bot Token (можно оставить пустым): ${NC}")" tg_bot_token
    read -rp "$(printf "${CYAN}Telegram Chat ID (можно оставить пустым): ${NC}")" tg_chat_id
    echo ""
    info "AI Анализ (Qwen — основной, Gemini — запасной)"
    read -rp "$(printf "${CYAN}Qwen API Token (можно оставить пустым): ${NC}")" qwen_token
    read -rp "$(printf "${CYAN}Gemini API Token (можно оставить пустым): ${NC}")" gemini_token

    local ai_enabled="false"
    if [ -n "$qwen_token" ] || [ -n "$gemini_token" ]; then
        ai_enabled="true"
    fi

    if [ -d "$VPNGUARD_CONFIG" ]; then
        warn "Обнаружена ошибочная папка $VPNGUARD_CONFIG (создана Docker), удаление..."
        rm -rf "$VPNGUARD_CONFIG"
    fi

    mkdir -p "$(dirname "$VPNGUARD_CONFIG")"
    cat > "$VPNGUARD_CONFIG" <<EOF
node_name: "${node_name}"
log_file: "/var/log/remnanode/access.log"
alert_log: "/app/guard_alerts.log"

telegram:
  bot_token: "${tg_bot_token}"
  chat_id: "${tg_chat_id}"

ai:
  enabled: ${ai_enabled}
  prompt: |
    Проанализируй логи Xray. Твоя задача — выявить нарушения правил использования VPN.

    Технические маркеры нарушений:
    - Торренты (P2P): частые соединения на разные нестандартные (высокие) порты.
    - Рассылка спама: TCP-соединения на порты 25, 465, 587.
    - Сканирование портов: запросы на множество разных портов одного IP или перебор IP-адресов.
    - DDoS-атаки / Флуд: аномально большое количество соединений с одним целевым IP за короткое время.
    - Вредоносное ПО / Ботнет: обращения к известным подозрительным портам или массовые однотипные запросы.

    Формат ответа строго 3 строки, без приветствий и лишних рассуждений:
    Строка 1: [НАРУШЕНИЕ] / [ПОДОЗРИТЕЛЬНО] / [ЧИСТО]
    Строка 2: Причина: <конкретный пункт правил или прочерк>
    Строка 3: Доказательства: <выжимка фактов из лога: протокол, целевые порты, частота>
  qwen_token: "${qwen_token}"
  qwen_url: "https://qwen.aikit.club/v1"
  qwen_model: "qwen3.5-flash"
  gemini_token: "${gemini_token}"

scoring:
  threshold: 800
  window_seconds: 60
  alert_cooldown: 120
  points:
    domain: 1
    ip: 3
    whitelist: 0.8
    spam: 50
    local_net: 10
    ssh: 15
    suspicious_port: 30
  spam_ports:
    - "25"
    - "465"
    - "587"
  suspicious_ports:
    - "22"
    - "23"
    - "445"
    - "3389"
    - "1433"
    - "3306"
  local_nets:
    - "192.168."
    - "10."
    - "172.16."
    - "127.0.0.1"
    - "localhost"

whitelist:
  domains:
    - google
    - youtube
    - googlevideo
    - gmail
    - gstatic
    - doubleclick
    - android
    - facebook
    - fbcdn
    - instagram
    - whatsapp
    - meta
    - cdninstagram
    - apple
    - icloud
    - itunes
    - iphone
    - push.apple.com
    - tiktok
    - tiktokcdn
    - tiktokv
    - netflix
    - nflxvideo
    - microsoft
    - windowsupdate
    - azure
    - office
    - amazon
    - aws
    - telegram
    - spotify
    - yandex
    - ya.ru
    - kinopoisk
    - vk.com
    - ok.ru
    - vkuser
    - userapi
    - mail.ru
    - steam
    - valve
    - epicgames
    - discord
    - avito
    - ozon
    - wildberries
    - wb.ru
    - openai
    - chatgpt
    - anthropic
    - claude
    - gemini
    - deepseek
    - github
    - githubusercontent
    - copilot
  trusted_ip_prefixes:
    - "149.154."
    - "91.108."
    - "5.28."
    - "91.105."
    - "95.161."
    - "2001:67c:"
    - "2001:b28:"
    - "173.194."
    - "74.125."
    - "142.250."
    - "142.251."
    - "162.159."
    - "199.103."
    - "35.214."
    - "104.16."
    - "104.17."
    - "104.18."
    - "104.19."
    - "104.20."
    - "104.21."
    - "172.64."
    - "172.67."
    - "199.232."
    - "92.223."
    - "185.106."
    - "87.240."
    - "95.163."
    - "93.186."
    - "95.213."
    - "95.142."
    - "185.32."
    - "185.89."
    - "185.116."
    - "130.49."
    - "62.217."
    - "94.100."
    - "155.212."
    - "178.237."
    - "217.16."
    - "217.20."
    - "217.69."
    - "5.61."
    - "79.137."
    - "83.166."
    - "87.239."
    - "90.156."
    - "128.140."
    - "161.104."
    - "176.112."
    - "178.22."
    - "188.93."
    - "212.233."
    - "5.101."
    - "5.181."
    - "5.188."
    - "31.177."
    - "37.139."
    - "45.84."
    - "45.136."
    - "83.217."
    - "83.222."
    - "84.23."
    - "85.192."
    - "87.242."
    - "89.208."
    - "89.221."
    - "91.219."
    - "91.231."
    - "94.139."
    - "109.120."
    - "146.185."
    - "185.5."
    - "185.16."
    - "185.86."
    - "185.100."
    - "185.130."
    - "185.131."
    - "185.180."
    - "185.226."
    - "185.241."
    - "193.203."
    - "195.211."
    - "212.111."
    - "213.219."
    - "217.174."
    - "195.218."
    - "92.38."
    - "185.187."
    - "194.186."
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
    build: ./src/vpnguard
    container_name: vpnguard
    restart: unless-stopped
    volumes:
      - ./config/config.yaml:/app/vpnguard.yaml:ro
      - /var/log/remnanode:/var/log/remnanode:ro
      - ./reports:/app/reports
      - ./guard_alerts.log:/app/guard_alerts.log
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
    (trap - INT; compose_vpnguard logs --tail=200 -f)
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
        local qwen_token qwen_model gemini_token ai_enabled
        node_name="$(vpnguard_get_value "node_name")"
        bot_token="$(vpnguard_get_value "  bot_token")"
        chat_id="$(vpnguard_get_value "  chat_id")"
        threshold="$(vpnguard_get_value "  threshold")"
        cooldown="$(vpnguard_get_value "  alert_cooldown")"
        qwen_token="$(vpnguard_get_value "  qwen_token")"
        qwen_model="$(vpnguard_get_value "  qwen_model")"
        gemini_token="$(vpnguard_get_value "  gemini_token")"
        ai_enabled="$(vpnguard_get_value "  enabled")"
        
        status_line="$(get_docker_status "vpnguard")"

        printf "${BLUE}─── Текущая конфигурация ────────── ${status_line} ──${NC}\n"
        printf "  • Имя ноды:       ${BOLD}%s${NC}\n" "${node_name}"
        printf "  • Бот Токен:      ${BOLD}%s${NC}\n" "$(vpnguard_mask_token "$bot_token")"
        printf "  • Chat ID:        ${BOLD}%s${NC}\n" "${chat_id:-"(не задан)"}"
        printf "  • Порог/Кулдаун:  ${BOLD}%s баллов / %s сек.${NC}\n" "${threshold}" "${cooldown}"
        printf "${BLUE}─── AI Анализ ──────────────────────────────────────${NC}\n"
        printf "  • AI:          ${BOLD}%s${NC}\n" "${ai_enabled}"
        printf "  • Qwen токен:  ${BOLD}%s${NC}\n" "$(vpnguard_mask_token "$qwen_token")"
        printf "  • Qwen модель: ${BOLD}%s${NC}\n" "${qwen_model:-"(не задана)"}"
        printf "  • Gemini:      ${BOLD}%s${NC}\n" "$(vpnguard_mask_token "$gemini_token")"
        printf "${BLUE}─────────────────────────────────────────────────────${NC}\n"
        echo ""
        printf "${BOLD}  1)${NC} Изменить Telegram Bot Token\n"
        printf "${BOLD}  2)${NC} Изменить Telegram Chat ID\n"
        printf "${BOLD}  3)${NC} Изменить имя ноды\n"
        printf "${BOLD}  4)${NC} Изменить порог баллов\n"
        printf "${BOLD}  5)${NC} Изменить кулдаун алерта\n"
        echo ""
        printf "${BLUE}─── AI ─────────────────────────────────────────────${NC}\n"
        printf "${BOLD}  7)${NC} Изменить Qwen токен\n"
        printf "${BOLD}  8)${NC} Изменить модель Qwen (показать список)\n"
        printf "${BOLD}  9)${NC} Изменить Gemini токен\n"
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
            7)
                read -rp "$(printf "${CYAN}Новый Qwen API Token: ${NC}")" value
                vpnguard_update_config_value "  qwen_token" "\"${value}\""
                if [ -n "$value" ]; then
                    vpnguard_update_config_value "  enabled" "true"
                fi
                compose_vpnguard restart
                ;;
            8)
                info "Запрашиваю список моделей Qwen..."
                echo ""
                compose_vpnguard run --rm vpnguard --list-models 2>/dev/null
                echo ""
                read -rp "$(printf "${CYAN}Введите имя модели: ${NC}")" value
                if [ -n "$value" ]; then
                    vpnguard_update_config_value "  qwen_model" "\"${value}\""
                    compose_vpnguard restart
                fi
                ;;
            9)
                read -rp "$(printf "${CYAN}Новый Gemini API Token: ${NC}")" value
                vpnguard_update_config_value "  gemini_token" "\"${value}\""
                if [ -n "$value" ]; then
                    vpnguard_update_config_value "  enabled" "true"
                fi
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
    ensure_docker || { error "Без Docker установка Beszel невозможна."; press_enter; return 1; }

    # 2. Создание папки
    local BESZEL_DIR="/opt/beszel"
    mkdir -p "$BESZEL_DIR"
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
    if [ -f "$BESZEL_DIR/docker-compose.yml" ]; then
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
    require_commands nano || { press_enter; return 1; }
    cp -p "$BESZEL_DIR/docker-compose.yml" "$BESZEL_DIR/docker-compose.yml.bak" 2>/dev/null || true
    chmod 0600 "$BESZEL_DIR/docker-compose.yml.bak" 2>/dev/null || true
    sleep 1
    nano "$BESZEL_DIR/docker-compose.yml"
    chmod 0600 "$BESZEL_DIR/docker-compose.yml" 2>/dev/null || true

    if [ ! -s "$BESZEL_DIR/docker-compose.yml" ]; then
        warn "docker-compose.yml пуст. Установка прервана."
        press_enter
        return
    fi
    if ! compose_validate "$BESZEL_DIR"; then
        [ -f "$BESZEL_DIR/docker-compose.yml.bak" ] && cp -p "$BESZEL_DIR/docker-compose.yml.bak" "$BESZEL_DIR/docker-compose.yml"
        error "Compose-конфигурация некорректна; предыдущая версия восстановлена."
        press_enter
        return 1
    fi

    # 4. Настройка UFW
    echo ""
    read -rp "$(printf "${CYAN}Введите IP-адрес Beszel Hub для доступа к порту 45876: ${NC}")" hub_ip
    if [ -n "$hub_ip" ]; then
        if ! is_valid_ip "$hub_ip"; then error "Некорректный IPv4-адрес Hub."; press_enter; return 1; fi
        if ! command -v ufw &>/dev/null; then error "UFW не установлен; правило доступа не добавлено."; press_enter; return 1; fi
        info "Разрешаем доступ к порту 45876 для $hub_ip..."
        ufw allow from "$hub_ip" to any port 45876 proto tcp || { error "Не удалось добавить правило UFW."; press_enter; return 1; }
        success "Доступ разрешен."
    else
        warn "IP не введен. Порт 45876 не открыт автоматически."
    fi

    # 5. Запуск
    info "Запуск контейнера Beszel Agent..."
    if compose_run "$BESZEL_DIR" up -d; then
        success "Beszel Agent запущен."
    else
        error "Не удалось запустить Beszel Agent."
    fi
    press_enter
}

do_uninstall_warp() {
    header "Удаление Cloudflare WARP" "Сервисы"
    local mode=${1:-interactive}
    if [ "$mode" = "interactive" ] && ! confirm_action "Удалить WARP полностью"; then
        info "Отменено."
        press_enter
        return
    fi

    info "Остановка интерфейса warp..."
    if ip link show warp &>/dev/null; then
        wg-quick down warp &>/dev/null || true
    fi
    systemctl stop wg-quick@warp 2>/dev/null || true
    systemctl disable wg-quick@warp 2>/dev/null || true

    info "Удаление файлов и пакетов..."
    rm -f /etc/wireguard/warp.conf /etc/wireguard/wgcf-account.toml
    rm -f /usr/local/bin/wgcf

    # Пакет wireguard удаляем только если пользователь уверен (может использоваться другими)
    if [ "$mode" = "interactive" ] && confirm_action "Удалить пакет wireguard (может использоваться другими сервисами)"; then
        apt-get remove --purge -y wireguard
        apt-get autoremove -y
    fi

    success "WARP удалён."
    [ "$mode" = "interactive" ] && press_enter
}

do_install_warp() {
    header "Установка Cloudflare WARP" "Сервисы"

    # 1. Проверка установки
    if command -v wgcf >/dev/null 2>&1 && [ -f "/etc/wireguard/warp.conf" ]; then
        warn "WARP уже установлен."
        if ! confirm_action "Переустановить WARP"; then return; fi
        do_uninstall_warp reinstall || return 1
        [ -f /etc/wireguard/warp.conf ] && { error "Старый WARP не удалён."; press_enter; return 1; }
    fi

    # 2. Установка WireGuard
    info "Установка WireGuard..."
    if ! measure_time bash -c "apt-get update -qq && apt-get install -y wireguard wget curl jq"; then
        error "Не удалось установить зависимости WARP."
        press_enter
        return 1
    fi
    
    # 3. Скачивание wgcf
    info "Скачивание wgcf..."
    local ARCH WGCF_ARCH WGCF_RELEASE_URL WGCF_VERSION WGCF_DOWNLOAD_URL
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        *) error "Архитектура $ARCH не поддерживается wgcf."; press_enter; return 1 ;;
    esac
    
    WGCF_RELEASE_URL="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    WGCF_VERSION=$(curl -fsSL "$WGCF_RELEASE_URL" | jq -r '.tag_name // empty')
    if [ -z "$WGCF_VERSION" ]; then error "Не удалось определить версию wgcf."; press_enter; return 1; fi
    WGCF_DOWNLOAD_URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}"
    
    if ! download_atomic "$WGCF_DOWNLOAD_URL" /usr/local/bin/wgcf; then error "Не удалось скачать wgcf."; press_enter; return 1; fi
    chmod +x /usr/local/bin/wgcf
    success "wgcf установлен."

    # 4. Регистрация и генерация
    info "Регистрация аккаунта WARP..."
    local wgcf_workdir
    wgcf_workdir=$(mktemp -d /tmp/qi-wgcf.XXXXXX) || { error "Не удалось создать временный каталог."; press_enter; return 1; }
    if ! (cd "$wgcf_workdir" && yes | wgcf register && wgcf generate); then
        rm -rf "$wgcf_workdir"
        error "Регистрация или генерация профиля WARP завершилась ошибкой."
        press_enter
        return 1
    fi
    
    if [ ! -f "$wgcf_workdir/wgcf-profile.conf" ]; then
        rm -rf "$wgcf_workdir"
        error "Не удалось сгенерировать конфиг wgcf-profile.conf"
        press_enter
        return 1
    fi

    # 5. Оптимизация конфига для сервера
    info "Настройка конфигурации (Table = off)..."
    # Удаляем DNS из конфига, чтобы не сломать системный резолвер
    sed -i '/^DNS =/d' "$wgcf_workdir/wgcf-profile.conf"
    # Добавляем Table = off, чтобы не перехватывать ВЕСЬ трафик (опасно для SSH)
    if ! grep -q "Table = off" "$wgcf_workdir/wgcf-profile.conf"; then
        sed -i '/^MTU =/a Table = off' "$wgcf_workdir/wgcf-profile.conf"
    fi
    # Добавляем Keepalive
    if ! grep -q "PersistentKeepalive" "$wgcf_workdir/wgcf-profile.conf"; then
        sed -i '/^Endpoint =/a PersistentKeepalive = 25' "$wgcf_workdir/wgcf-profile.conf"
    fi

    # 6. IPv6 Check
    if ! (sysctl net.ipv6.conf.all.disable_ipv6 | grep -q ' = 0'); then
        info "IPv6 отключен в системе, удаляем его из конфига WARP..."
        sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "$wgcf_workdir/wgcf-profile.conf"
        sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$wgcf_workdir/wgcf-profile.conf"
    fi

    # 7. Установка конфига
    mkdir -p /etc/wireguard
    install -m 0600 "$wgcf_workdir/wgcf-profile.conf" /etc/wireguard/warp.conf
    [ -f "$wgcf_workdir/wgcf-account.toml" ] && install -m 0600 "$wgcf_workdir/wgcf-account.toml" /etc/wireguard/wgcf-account.toml
    rm -rf "$wgcf_workdir"
    
    # 8. Запуск
    info "Запуск интерфейса warp..."
    if ! systemctl enable --now wg-quick@warp; then
        error "Не удалось запустить wg-quick@warp."
        press_enter
        return 1
    fi
    
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
        header "Cloudflare WARP" "Сервисы"
        menu_section "Управление"
        menu_item 1 "Установить или переустановить WARP"
        menu_item 2 "Удалить WARP"
        menu_item 3 "Показать статус"
        menu_item 4 "Перезапустить WARP"
        menu_back
        read_choice choice

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
    ensure_docker || { error "Без Docker установка AdGuard Home невозможна."; press_enter; return 1; }

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
    local docker_bridge_ip
    docker_bridge_ip=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
    if ! is_valid_ip "$docker_bridge_ip"; then
        error "Не удалось определить IPv4 gateway стандартной Docker-сети bridge."
        press_enter
        return 1
    fi
    [ -f "${AGH_DIR}/docker-compose.yml" ] && cp -p "${AGH_DIR}/docker-compose.yml" "${AGH_DIR}/docker-compose.yml.bak"
    chmod 0600 "${AGH_DIR}/docker-compose.yml.bak" 2>/dev/null || true
    cat > "${AGH_DIR}/docker-compose.yml" <<EOF
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    ports:
      # DNS выводим в сеть Docker (чтобы Xray его увидел)
      - "${docker_bridge_ip}:5353:53/tcp"
      - "${docker_bridge_ip}:5353:53/udp"
      # Порт для мастера первоначальной настройки (скрыт от интернета)
      - "127.0.0.1:3000:3000/tcp"
      # Порт для самой веб-панели (скрыт от интернета)
      - "127.0.0.1:8080:80/tcp"
    volumes:
      - ./workdir:/opt/adguardhome/work
      - ./confdir:/opt/adguardhome/conf
EOF
    chmod 0600 "${AGH_DIR}/docker-compose.yml"

    # 3. Редактирование AdGuardHome.yaml
    info "Сейчас откроется nano для редактирования AdGuardHome.yaml"
    info "Вставьте ваш конфиг и сохраните (Ctrl+O, Enter, Ctrl+X)"
    require_commands nano || { press_enter; return 1; }
    [ -f "${AGH_DIR}/confdir/AdGuardHome.yaml" ] && cp -p "${AGH_DIR}/confdir/AdGuardHome.yaml" "${AGH_DIR}/confdir/AdGuardHome.yaml.bak"
    chmod 0600 "${AGH_DIR}/confdir/AdGuardHome.yaml.bak" 2>/dev/null || true
    sleep 1
    nano "${AGH_DIR}/confdir/AdGuardHome.yaml"
    chmod 0600 "${AGH_DIR}/confdir/AdGuardHome.yaml" 2>/dev/null || true

    if [ ! -s "${AGH_DIR}/confdir/AdGuardHome.yaml" ]; then
        [ -f "${AGH_DIR}/confdir/AdGuardHome.yaml.bak" ] && cp -p "${AGH_DIR}/confdir/AdGuardHome.yaml.bak" "${AGH_DIR}/confdir/AdGuardHome.yaml"
        error "Конфигурация пуста; предыдущий файл восстановлен."
        press_enter
        return 1
    fi
    if ! compose_validate "$AGH_DIR"; then
        [ -f "${AGH_DIR}/docker-compose.yml.bak" ] && cp -p "${AGH_DIR}/docker-compose.yml.bak" "${AGH_DIR}/docker-compose.yml"
        error "Compose-конфигурация AdGuard некорректна."
        press_enter
        return 1
    fi

    # 4. Запуск
    info "Запуск контейнера..."
    if compose_run "$AGH_DIR" up -d; then
        success "AdGuard Home установлен и запущен."
    else
        error "Не удалось запустить AdGuard Home."
    fi
    press_enter
}

do_start_adguard() {
    header "Запуск AdGuard Home" "Сервисы > AdGuard Home"
    if compose_run "$AGH_DIR" up -d; then success "Выполнено."; else error "Не удалось запустить AdGuard Home."; fi
    press_enter
}

do_stop_adguard() {
    header "Остановка AdGuard Home" "Сервисы > AdGuard Home"
    if compose_run "$AGH_DIR" stop; then success "Выполнено."; else error "Не удалось остановить AdGuard Home."; fi
    press_enter
}

do_restart_adguard() {
    header "Перезапуск AdGuard Home" "Сервисы > AdGuard Home"
    if compose_run "$AGH_DIR" restart; then success "Выполнено."; else error "Не удалось перезапустить AdGuard Home."; fi
    press_enter
}

do_logs_adguard() {
    header "Логи AdGuard Home" "Сервисы > AdGuard Home"
    compose_run "$AGH_DIR" logs -f --tail=100
}

do_edit_adguard_yaml() {
    header "Редактирование AdGuardHome.yaml" "Сервисы > AdGuard Home"
    if [ -f "${AGH_DIR}/confdir/AdGuardHome.yaml" ]; then
        require_commands nano || { press_enter; return 1; }
        cp -p "${AGH_DIR}/confdir/AdGuardHome.yaml" "${AGH_DIR}/confdir/AdGuardHome.yaml.bak"
        chmod 0600 "${AGH_DIR}/confdir/AdGuardHome.yaml.bak" 2>/dev/null || true
        nano "${AGH_DIR}/confdir/AdGuardHome.yaml"
        chmod 0600 "${AGH_DIR}/confdir/AdGuardHome.yaml" 2>/dev/null || true
        if [ -s "${AGH_DIR}/confdir/AdGuardHome.yaml" ]; then
            success "Редактирование завершено."
        else
            cp -p "${AGH_DIR}/confdir/AdGuardHome.yaml.bak" "${AGH_DIR}/confdir/AdGuardHome.yaml"
            error "Пустая конфигурация не сохранена; восстановлен бэкап."
        fi
    else
        error "Файл конфигурации не найден!"
    fi
    press_enter
}

do_overwrite_adguard_yaml() {
    header "Перезапись AdGuardHome.yaml" "Сервисы > AdGuard Home"
    warn "Это действие полностью ОЧИСТИТ текущий конфиг!"
    read -rp "$(printf "${YELLOW}Вы уверены, что хотите продолжить? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

    local yaml_path="${AGH_DIR}/confdir/AdGuardHome.yaml"
    require_commands nano || { press_enter; return 1; }
    [ -f "$yaml_path" ] && cp -p "$yaml_path" "${yaml_path}.bak"
    chmod 0600 "${yaml_path}.bak" 2>/dev/null || true
    # Очищаем файл
    : > "$yaml_path"
    info "Файл очищен. Сейчас откроется nano..."
    sleep 1
    nano "$yaml_path"
    chmod 0600 "$yaml_path" 2>/dev/null || true
    if [ ! -s "$yaml_path" ]; then
        [ -f "${yaml_path}.bak" ] && cp -p "${yaml_path}.bak" "$yaml_path"
        error "Пустой конфиг отклонён; восстановлена предыдущая версия."
        press_enter
        return 1
    fi
    
    info "Перезапуск контейнера для применения нового конфига..."
    if compose_run "$AGH_DIR" restart; then
        success "Конфигурация обновлена и AdGuard Home перезапущен."
    else
        error "Конфигурация сохранена, но контейнер не перезапустился."
    fi
    press_enter
}

menu_adguard() {
    while true; do
        clear
        header "AdGuard Home" "Сервисы"
        menu_section "Состояние: $(get_docker_status "adguardhome")"
        menu_item 1 "Установить с нуля"
        menu_item 2 "Запустить"
        menu_item 3 "Остановить"
        menu_item 4 "Перезапустить"
        menu_item 5 "Показать логи"
        echo ""
        menu_section "Конфигурация"
        menu_item 6 "Редактировать AdGuardHome.yaml"
        menu_item 7 "Пересоздать AdGuardHome.yaml"
        menu_back
        read_choice choice

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
    header "Trafficguard Pro Manager" "Безопасность"
    if command -v rknpidor &>/dev/null; then
        rknpidor
    else
        warn "Команда rknpidor не найдена."
        read -rp "$(printf "${YELLOW}Хотите установить Trafficguard Pro? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка Trafficguard Pro..."
            if run_remote_script "https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh"; then
                success "Установка завершена."
            else
                error "Установка Trafficguard завершилась ошибкой."
            fi
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
        menu_section "Инструменты"
        menu_item 1 "Управление UFW"
        menu_item 2 "Trafficguard Pro Manager"
        menu_back
        read_choice choice

        case "$choice" in
            1) menu_ufw ;;
            2) do_trafficguard ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

do_install_logs() {
    header "Установка системы логов" "Мониторинг"

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
    chmod 0775 "$LOG_DIR"
    chmod 0664 "$LOG_DIR/access.log" "$LOG_DIR/error.log"
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
    success "Logrotate настроен."

    # 4. Volume в docker-compose.yml
    if [ -f "$COMPOSE_FILE" ]; then
        cp -p "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
        chmod 0600 "$COMPOSE_FILE.bak" 2>/dev/null || true
        if grep -q "/var/log/remnanode:/var/log/remnanode" "$COMPOSE_FILE"; then
            info "Volume для логов уже есть в docker-compose.yml."
        else
            info "Добавляю volume в docker-compose.yml..."
            if grep -E -q '^[ \t]+volumes:' "$COMPOSE_FILE"; then
                awk -v vol="      - \"/var/log/remnanode:/var/log/remnanode\"" '/^[ \t]+volumes:/ && !done { print; print vol; done=1; next } 1' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
            else
                sed -i '/SECRET_KEY/a \    volumes:\n      - "/var/log/remnanode:/var/log/remnanode"' "$COMPOSE_FILE"
            fi
            chmod 0600 "$COMPOSE_FILE" 2>/dev/null || true
            if compose_validate "$REMNA_DIR"; then
                success "Volume добавлен."
            else
                cp -p "$COMPOSE_FILE.bak" "$COMPOSE_FILE"
                error "Изменение Compose отклонено; восстановлена резервная копия."
                press_enter
                return 1
            fi
        fi

        # 5. Рестарт
        info "Перезапуск контейнера..."
        if compose_run "$REMNA_DIR" up -d; then success "Контейнер перезапущен."; else error "Ошибка перезапуска контейнера."; fi
    else
        warn "docker-compose.yml не найден. Volume нужно будет добавить вручную."
    fi

    echo ""
    printf "${GREEN}══════════════════════════════════════════${NC}\n"
    printf "${GREEN}  СИСТЕМА ЛОГОВ ГОТОВА!${NC}\n"
    printf "${GREEN}══════════════════════════════════════════${NC}\n"
    echo ""
    printf "Зайди в панель управления нодой и добавь в конфиг:\n"
    printf "${YELLOW}"
    echo '  "log": {'
    echo '    "access": "/var/log/remnanode/access.log",'
    echo '    "error": "/var/log/remnanode/error.log",'
    echo '    "loglevel": "warning"'
    echo '  },'
    printf "${NC}\n"
    printf "После сохранения в панели, логи полетят в $LOG_DIR\n"
    press_enter
}

menu_monitoring() {
    while true; do
        clear
        header "Мониторинг" "Главное меню"
        menu_section "Сервисы мониторинга"
        menu_item 1 "Beszel Agent"
        menu_item 2 "VPN Guard"
        menu_item 3 "Ротация логов Remnanode"
        menu_back
        read_choice choice

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
        menu_section "Доступные сервисы"
        menu_item 1 "AdGuard Home"
        menu_item 2 "Cloudflare WARP"
        menu_back
        read_choice choice

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
    header "Проверка IP Region — все внешние IPv4" "Тесты"

    local ipregion_script
    local local_ip
    local external_ip
    local -a local_ips=()
    local -a tested_external_ips=()

    ipregion_script="$(mktemp)" || {
        error "Не удалось создать временный файл."
        press_enter
        return
    }

    if ! download_atomic "https://ipregion.vrnt.xyz" "$ipregion_script"; then
        error "Не удалось скачать ipregion."
        rm -f "$ipregion_script"
        press_enter
        return
    fi

    # Получаем все IPv4, назначенные серверу (исключая docker и виртуальные мосты).
    mapfile -t local_ips < <(
        ip -o -4 addr show scope global 2>/dev/null |
        awk '$2 !~ /^(docker|br-|veth|lo)/ {
            split($4, address, "/")
            print address[1]
        }' |
        sort -u
    )

    if (( ${#local_ips[@]} == 0 )); then
        error "На сервере не найдены IPv4-адреса."
        rm -f "$ipregion_script"
        press_enter
        return
    fi

    for local_ip in "${local_ips[@]}"; do
        # Проверяем, может ли этот адрес использоваться для выхода в интернет.
        external_ip="$(
            curl -4fsS \
                --connect-timeout 5 \
                --max-time 10 \
                --interface "$local_ip" \
                https://api.ipify.org 2>/dev/null |
            tr -d '\r\n'
        )"

        if [[ -z "$external_ip" ]]; then
            continue
        fi

        # Пропускаем, если этот внешний IP уже проверяли
        local already_tested=0
        for prev_ext in "${tested_external_ips[@]}"; do
            if [[ "$prev_ext" == "$external_ip" ]]; then
                already_tested=1
                break
            fi
        done

        if (( already_tested )); then
            continue
        fi

        tested_external_ips+=("$external_ip")

        echo ""
        printf "${CYAN}══════════════════════════════════════════════════════${NC}\n"
        if [[ "$local_ip" != "$external_ip" ]]; then
            printf "${BOLD}Локальный IP:${NC} %s\n" "$local_ip"
        fi
        printf "${BOLD}Внешний IP:${NC}  %s\n" "$external_ip"
        printf "${CYAN}══════════════════════════════════════════════════════${NC}\n"

        # Принудительно запускаем ipregion через конкретный IP.
        bash "$ipregion_script" -4 -i "$local_ip"
    done

    rm -f "$ipregion_script"

    echo ""
    if (( ${#tested_external_ips[@]} > 0 )); then
        success "Проверено уникальных внешних IPv4: ${#tested_external_ips[@]}"
    else
        warn "Не найдено IPv4-адресов с доступом в интернет."
    fi

    press_enter
}

do_test_censor_geoblock() {
    header "Censorcheck: Проверка геоблока" "Тесты"
    run_remote_script "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" --mode geoblock || error "Тест завершился ошибкой."
    press_enter
}

do_test_censor_dpi() {
    header "Censorcheck: Проверка DPI (РФ)" "Тесты"
    run_remote_script "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" --mode dpi || error "Тест завершился ошибкой."
    press_enter
}

do_test_ip_quality_place() {
    header "Проверка IP (IP.Check.Place)" "Тесты"
    run_remote_script "https://IP.Check.Place" -l en || error "Тест завершился ошибкой."
    press_enter
}

do_test_ip_quality_check() {
    header "IP Quality (Check.Place)" "Тесты"
    run_remote_script "https://Check.Place" -EI || error "Тест завершился ошибкой."
    press_enter
}

do_test_iperf_ru() {
    header "Тест скорости до RU iPerf3 серверов" "Тесты"
    run_remote_script "https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh" || error "Тест завершился ошибкой."
    press_enter
}

do_test_yabs() {
    header "Yet Another Bench Script (YABS)" "Тесты"
    info "Запуск YABS (только IPv4)..."
    run_remote_script "https://yabs.sh" -4 || error "YABS завершился ошибкой."
    press_enter
}

do_test_bench_sh() {
    header "Bench.sh" "Тесты"
    info "Запуск классического теста..."
    run_remote_script "https://bench.sh" || error "Bench.sh завершился ошибкой."
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
        menu_section "IP и блокировки"
        menu_item 1 "Проверить регион IP"
        menu_item 2 "Censorcheck: геоблок"
        menu_item 3 "Censorcheck: DPI"
        menu_item 4 "IP.Check.Place"
        menu_item 5 "IP Quality"
        echo ""
        menu_section "Производительность"
        menu_item 6 "Скорость до RU iPerf3"
        menu_item 7 "YABS"
        menu_item 8 "Bench.sh"
        menu_item 9 "CPU через sysbench"
        echo ""
        menu_section "Диагностика"
        menu_item 10 "Комплексная диагностика ноды"
        menu_back
        read_choice choice

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
            10) do_run_diagnostics ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}
