#!/usr/bin/env bash
# ============================================================
# setup.sh — Универсальный скрипт настройки сервера
# Запуск: sudo bash setup.sh
# ============================================================

set -o pipefail

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Константы ───────────────────────────────────────────────
REMNA_DIR="/opt/remnanode"
LOG_DIR="/var/log/remnanode"
COMPOSE_FILE="${REMNA_DIR}/docker-compose.yml"

# Watchdog — данные запрашиваются при установке

# ─── Вспомогательные функции ─────────────────────────────────
info()    { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✔]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[⚠]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✘]${NC} %s\n" "$*"; }

header() {
    echo ""
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${BOLD}  %s${NC}\n" "$*"
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

press_enter() {
    echo ""
    read -rp "$(printf "${YELLOW}Нажмите Enter для продолжения...${NC}")" _
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Требуются права root. Запустите: sudo bash setup.sh"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ═══════════════════════════════════════════════════════════════
do_update() {
    header "Обновление системы"
    info "Обновление списка пакетов..."
    apt update
    info "Обновление установленных пакетов..."
    apt upgrade -y
    success "Система обновлена."
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 2. УПРАВЛЕНИЕ UFW
# ═══════════════════════════════════════════════════════════════
ufw_enable_secure() {
    header "Включение UFW (Безопасное)"
    info "Разрешаем OpenSSH..."
    ufw allow OpenSSH
    info "Добавляем защиту SSH от брутфорса (rate limit)..."
    ufw limit ssh
    info "Включаем UFW..."
    echo "y" | ufw enable
    success "UFW включён. OpenSSH разрешён."
    ufw status verbose
    press_enter
}

ufw_enable_basic() {
    header "Простое включение UFW"
    
    # ПРОВЕРКА SSH
    if ! ufw status | grep -qE "22/(tcp|any).*ALLOW|OpenSSH.*ALLOW"; then
        warn "ВНИМАНИЕ: Порт SSH (22) или правило OpenSSH не найдены в списке разрешенных!"
        warn "Включение UFW может привести к потере доступа по SSH."
        echo ""
        read -rp "$(printf "${YELLOW}Вы уверены, что хотите продолжить? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Включение отменено."
            press_enter
            return
        fi
    fi

    info "Включаем UFW..."
    echo "y" | ufw enable
    success "UFW включён (без добавления новых правил)."
    ufw status verbose
    press_enter
}

ufw_disable() {
    header "Выключение UFW"
    ufw disable
    success "UFW выключен."
    press_enter
}

ufw_open_port() {
    header "Открытие порта"
    read -rp "Введите порт (или диапазон, напр. 8000:8100): " port
    read -rp "Протокол [tcp/udp/any] (Enter = any): " proto
    if [ -z "$proto" ] || [ "$proto" = "any" ]; then
        ufw allow "$port"
    else
        ufw allow "$port/$proto"
    fi
    success "Порт $port открыт."
    press_enter
}

ufw_open_port_ip() {
    header "Открытие порта для конкретного IP"
    read -rp "Введите IP-адрес: " ip
    read -rp "Введите порт: " port
    read -rp "Протокол [tcp/udp] (Enter = tcp): " proto
    proto=${proto:-tcp}
    ufw allow from "$ip" to any port "$port" proto "$proto"
    success "Порт $port открыт для IP $ip ($proto)."
    press_enter
}

ufw_close_port() {
    header "Закрытие порта"
    read -rp "Введите порт (или диапазон): " port
    read -rp "Протокол [tcp/udp/any] (Enter = any): " proto
    if [ -z "$proto" ] || [ "$proto" = "any" ]; then
        ufw deny "$port"
    else
        ufw deny "$port/$proto"
    fi
    success "Порт $port закрыт."
    press_enter
}

ufw_close_port_ip() {
    header "Закрытие порта для конкретного IP"
    read -rp "Введите IP-адрес: " ip
    read -rp "Введите порт: " port
    read -rp "Протокол [tcp/udp] (Enter = tcp): " proto
    proto=${proto:-tcp}
    ufw deny from "$ip" to any port "$port" proto "$proto"
    success "Порт $port закрыт для IP $ip ($proto)."
    press_enter
}

# Вспомогательная функция: устанавливает все ICMP-правила с указанным действием
# Подход: сначала удаляем ВСЕ старые ICMP-строки, потом вставляем нужные заново
# Это гарантирует отсутствие дублей при любом начальном состоянии файла
set_icmp_rules() {
    local file="$1" action="$2"  # action = DROP или ACCEPT

    # 1. Удаляем ВСЕ существующие ICMP-правила (и DROP и ACCEPT) из обеих секций
    sed -i '/-A ufw-before-input -p icmp --icmp-type .* -j \(ACCEPT\|DROP\)/d' "$file"
    sed -i '/-A ufw-before-forward -p icmp --icmp-type .* -j \(ACCEPT\|DROP\)/d' "$file"

    # 2. Вставляем INPUT правила после якоря (в обратном порядке, т.к. sed 'a' вставляет после)
    local input_anchor="# ok icmp codes for INPUT"
    if grep -qF "$input_anchor" "$file"; then
        sed -i "/${input_anchor}/a\\
-A ufw-before-input -p icmp --icmp-type destination-unreachable -j ${action}\\
-A ufw-before-input -p icmp --icmp-type time-exceeded -j ${action}\\
-A ufw-before-input -p icmp --icmp-type parameter-problem -j ${action}\\
-A ufw-before-input -p icmp --icmp-type echo-request -j ${action}\\
-A ufw-before-input -p icmp --icmp-type source-quench -j ${action}" "$file"
    fi

    # 3. Вставляем FORWARD правила после якоря
    local forward_anchor="# ok icmp code for FORWARD"
    if grep -qF "$forward_anchor" "$file"; then
        sed -i "/${forward_anchor}/a\\
-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j ${action}\\
-A ufw-before-forward -p icmp --icmp-type time-exceeded -j ${action}\\
-A ufw-before-forward -p icmp --icmp-type parameter-problem -j ${action}\\
-A ufw-before-forward -p icmp --icmp-type echo-request -j ${action}" "$file"
    fi
}

ufw_disable_ping() {
    header "Отключение пингования (ICMP DROP)"
    local rules_file="/etc/ufw/before.rules"

    if [ ! -f "$rules_file" ]; then
        error "Файл $rules_file не найден!"
        press_enter
        return
    fi

    # Бэкап
    cp "$rules_file" "${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    info "Бэкап создан."

    set_icmp_rules "$rules_file" "DROP"

    # Перезагружаем UFW для применения
    ufw reload 2>/dev/null || warn "UFW не перезагружен (возможно, не активен). Изменения применятся при включении."

    success "Пингование отключено (ICMP → DROP)."
    press_enter
}

ufw_enable_ping() {
    header "Включение пингования (ICMP ACCEPT)"
    local rules_file="/etc/ufw/before.rules"

    if [ ! -f "$rules_file" ]; then
        error "Файл $rules_file не найден!"
        press_enter
        return
    fi

    cp "$rules_file" "${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    info "Бэкап создан."

    set_icmp_rules "$rules_file" "ACCEPT"

    ufw reload 2>/dev/null || warn "UFW не перезагружен. Изменения применятся при включении."

    success "Пингование включено (ICMP → ACCEPT)."
    press_enter
}

ufw_status() {
    header "Статус UFW"
    ufw status numbered verbose
    press_enter
}

ufw_delete_rule() {
    header "Удаление правила UFW"
    ufw status numbered
    echo ""
    read -rp "Введите номер правила для удаления (или 0 для отмены): " rule_num
    if [ "$rule_num" != "0" ] && [ -n "$rule_num" ]; then
        echo "y" | ufw delete "$rule_num"
        success "Правило #$rule_num удалено."
    fi
    press_enter
}

menu_ufw() {
    while true; do
        clear
        header "Управление UFW"
        
        printf "${BLUE}─── Состояние ───────────────────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} Статус UFW (подробно)\n"
        printf "${BOLD}  2)${NC} Включить UFW (Базово — только запуск)\n"
        printf "${BOLD}  3)${NC} Включить UFW (Рекомендуется — +SSH +Limit)\n"
        printf "${BOLD}  4)${NC} Выключить UFW\n"
        echo ""
        printf "${BLUE}─── Управление портами ──────────────────────────────${NC}\n"
        printf "${BOLD}  5)${NC} Открыть порт (TCP/UDP)\n"
        printf "${BOLD}  6)${NC} Открыть порт для конкретного IP\n"
        printf "${BOLD}  7)${NC} Закрыть порт\n"
        printf "${BOLD}  8)${NC} Удалить правило по номеру\n"
        echo ""
        printf "${BLUE}─── Дополнительно ───────────────────────────────────${NC}\n"
        printf "${BOLD}  9)${NC} Запретить пинг (ICMP DROP)\n"
        printf "${BOLD} 10)${NC} Разрешить пинг (ICMP ACCEPT)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) ufw_status ;;
            2) ufw_enable_basic ;;
            3) ufw_enable_secure ;;
            4) ufw_disable ;;
            5) ufw_open_port ;;
            6) ufw_open_port_ip ;;
            7) ufw_close_port ;;
            8) ufw_delete_rule ;;
            9) ufw_disable_ping ;;
            10) ufw_enable_ping ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
# 3. УСТАНОВКА НОДЫ (Docker + docker-compose.yml)
# ═══════════════════════════════════════════════════════════════
do_install_node() {
    header "Установка ноды"

    # 0. Проверка запущенного контейнера
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
        warn "Контейнер 'remnanode' уже запущен!"
        read -rp "$(printf "${YELLOW}Вы уверены, что хотите переустановить ноду? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    fi

    # 1. Docker
    if command -v docker &>/dev/null; then
        info "Docker уже установлен: $(docker --version)"
    else
        info "Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        success "Docker установлен."
    fi

    # 2. Создание папки
    mkdir -p "$REMNA_DIR"
    info "Папка $REMNA_DIR создана."

    # 3. docker-compose.yml
    if [ -f "$COMPOSE_FILE" ]; then
        warn "Файл $COMPOSE_FILE уже существует."
        read -rp "$(printf "${YELLOW}Перезаписать? [y/N]: ${NC}")" overwrite
        if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
            info "Пропускаем создание docker-compose.yml."
            press_enter
            return
        fi
    fi

    info "Сейчас откроется nano для редактирования docker-compose.yml"
    info "Вставьте ваш конфиг и сохраните (Ctrl+O, Enter, Ctrl+X)"
    sleep 2
    nano "$COMPOSE_FILE"

    if [ -f "$COMPOSE_FILE" ] && [ -s "$COMPOSE_FILE" ]; then
        success "docker-compose.yml сохранён."
    else
        warn "docker-compose.yml пуст или не создан."
    fi
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 4. ЗАПУСК НОДЫ
# ═══════════════════════════════════════════════════════════════
do_start_node() {
    header "Запуск ноды"

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден! Сначала установите ноду (пункт 3)."
        press_enter
        return
    fi

    info "Запуск контейнера..."
    cd "$REMNA_DIR" && docker compose up -d

    success "Контейнер запущен. Показываю логи (Ctrl+C для выхода)..."
    echo ""
    docker compose logs -f -t || true
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 4.1 ОБНОВЛЕНИЕ НОДЫ
# ═══════════════════════════════════════════════════════════════
do_update_node() {
    header "Обновление ноды"

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден! Обновление невозможно."
        press_enter
        return
    fi

    info "Подтягивание новых образов (docker compose pull)..."
    cd "$REMNA_DIR" && docker compose pull
    
    info "Перезапуск контейнера..."
    docker compose down && docker compose up -d
    
    success "Обновление завершено. Показываю логи (Ctrl+C для выхода)..."
    echo ""
    docker compose logs -f -t || true
    press_enter
}

do_show_docker_logs() {
    header "Логи контейнера"
    if [ ! -d "$REMNA_DIR" ]; then
        error "Папка $REMNA_DIR не найдена."
        press_enter
        return
    fi
    info "Выход: Ctrl+C"
    echo ""
    cd "$REMNA_DIR" && docker compose logs -f
    press_enter
}

do_stop_node() {
    header "Остановка ноды"
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден!"
        press_enter
        return
    fi
    info "Остановка и удаление контейнеров..."
    cd "$REMNA_DIR" && docker compose down
    success "Нода остановлена."
    press_enter
}

do_restart_node() {
    header "Перезапуск ноды"
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден!"
        press_enter
        return
    fi
    info "Перезапуск (down + up)..."
    cd "$REMNA_DIR" && docker compose down && docker compose up -d
    success "Нода перезапущена."
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 4.2 ЗАГРУЗКА И ОБНОВЛЕНИЕ GEO ФАЙЛОВ
# ═══════════════════════════════════════════════════════════════
do_download_geo() {
    header "Загрузка/Обновление Geo файлов"

    # 1. Запросить ссылку
    read -rp "$(printf "${CYAN}Введите ссылку на geo файл (например, https://.../geosite.dat): ${NC}")" geo_url
    if [ -z "$geo_url" ]; then
        error "Ссылка не может быть пустой!"
        press_enter
        return
    fi

    # 2. Скачать и добавить в папку
    local geo_dir="${REMNA_DIR}/geo"
    mkdir -p "$geo_dir"
    
    # Получаем имя файла из ссылки (убираем параметры ?x=y если есть)
    local filename
    filename=$(basename "${geo_url%%\?*}")
    if [ -z "$filename" ]; then
        error "Не удалось определить имя файла."
        press_enter
        return
    fi

    info "Скачивание $filename в $geo_dir..."
    if ! wget -qO "${geo_dir}/${filename}" "$geo_url"; then
        error "Ошибка при скачивании файла!"
        press_enter
        return
    fi
    success "Файл $filename успешно скачан."

    # 3. Прописать в docker-compose.yml
    if [ -f "$COMPOSE_FILE" ]; then
        if grep -q "${geo_dir}/${filename}" "$COMPOSE_FILE"; then
            info "Volume для $filename уже прописан."
            read -rp "$(printf "${YELLOW}Перезапустить контейнер для применения обновлённого файла? [y/N]: ${NC}")" restart_confirm
            if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
                info "Перезапуск контейнера..."
                cd "$REMNA_DIR" && docker compose down && docker compose up -d
                success "Контейнер перезапущен."
            else
                info "Перезапуск пропущен."
            fi
        else
            read -rp "$(printf "${CYAN}Укажите путь внутри контейнера для монтирования [По умолчанию: /usr/local/share/xray]: ${NC}")" container_path
            container_path=${container_path:-/usr/local/share/xray}
            container_path="${container_path%/}"

            local volume_mapping="${geo_dir}/${filename}:${container_path}/${filename}:ro"
            info "Добавляю $filename в volumes..."

            # Пытаемся найти блок volumes:
            if grep -E -q '^[ \t]+volumes:' "$COMPOSE_FILE"; then
                awk -v vol="      - \"${volume_mapping}\"" '/^[ \t]+volumes:/ && !done { print; print vol; done=1; next } 1' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
            elif grep -q "SECRET_KEY" "$COMPOSE_FILE"; then
                sed -i "/SECRET_KEY/a \\    volumes:\\n      - \"${volume_mapping}\"" "$COMPOSE_FILE"
            elif grep -q "image:" "$COMPOSE_FILE"; then
                sed -i "/image:/a \\    volumes:\\n      - \"${volume_mapping}\"" "$COMPOSE_FILE"
            else
                warn "Не найдено место для автоматического добавления volume."
                warn "Добавьте строку '- \"${volume_mapping}\"' в docker-compose.yml вручную."
            fi

            if grep -q "${geo_dir}/${filename}" "$COMPOSE_FILE"; then
                success "Настройки docker-compose.yml обновлены."
                read -rp "$(printf "${YELLOW}Перезапустить контейнер для применения изменений? [y/N]: ${NC}")" restart_confirm
                if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
                    info "Перезапуск контейнера..."
                    cd "$REMNA_DIR" && docker compose down && docker compose up -d
                    success "Контейнер перезапущен."
                else
                    info "Перезапуск пропущен."
                fi
            fi
        fi
    else
        warn "Конфигурация docker-compose.yml не найдена."
    fi

    press_enter
}

do_show_access_logs() {
    header "Логи подключений (access.log)"
    local log_file="/var/log/remnanode/access.log"
    if [ ! -f "$log_file" ]; then
        error "Файл $log_file не найден."
        press_enter
        return
    fi
    info "Выход: Ctrl+C"
    echo ""
    tail -f "$log_file"
    press_enter
}

menu_node() {
    while true; do
        clear
        header "Управление Нодой"
        
        printf "${BLUE}─── Установка и Обновление ──────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} Установка ноды (Docker + Compose)\n"
        printf "${BOLD}  2)${NC} 🔄  Обновить ноду (Docker Pull)\n"
        echo ""
        printf "${BLUE}─── Управление состоянием ───────────────────────────${NC}\n"
        printf "${BOLD}  3)${NC} ▶️   Запустить (с логами)\n"
        printf "${BOLD}  4)${NC} 🔄  Перезапустить\n"
        printf "${BOLD}  5)${NC} 🛑  Остановить\n"
        echo ""
        printf "${BLUE}─── Логи и Мониторинг ───────────────────────────────${NC}\n"
        printf "${BOLD}  6)${NC} 📊  Только логи контейнера\n"
        printf "${BOLD}  7)${NC} 🌐  Логи подключений (access.log)\n"
        printf "${BOLD}  8)${NC} 📋  Настройка логов (Logrotate)\n"
        printf "${BOLD}  9)${NC} 🐕  Установка Watchdog (Мониторинг)\n"
        echo ""
        printf "${BLUE}─── Дополнительно ───────────────────────────────────${NC}\n"
        printf "${BOLD} 10)${NC} 🌍  Загрузить/Обновить Geo файлы\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_node ;;
            2) do_update_node ;;
            3) do_start_node ;;
            4) do_restart_node ;;
            5) do_stop_node ;;
            6) do_show_docker_logs ;;
            7) do_show_access_logs ;;
            8) do_install_logs ;;
            9) do_install_watchdog ;;
            10) do_download_geo ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
# 4.3 ТЕСТЫ И БЕНЧМАРКИ
# ═══════════════════════════════════════════════════════════════

do_test_ip_region() {
    header "Проверка IP Region"
    bash <(wget -qO- https://ipregion.vrnt.xyz)
    press_enter
}

do_test_censor_geoblock() {
    header "Censorcheck: Проверка геоблока"
    bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode geoblock
    press_enter
}

do_test_censor_dpi() {
    header "Censorcheck: Проверка DPI (РФ)"
    bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi
    press_enter
}

do_test_iperf_ru() {
    header "Тест скорости до RU iPerf3 серверов"
    bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)
    press_enter
}

do_test_yabs() {
    header "Yet Another Bench Script (YABS)"
    info "Запуск YABS (только IPv4)..."
    curl -sL yabs.sh | bash -s -- -4
    press_enter
}

do_test_ip_quality_place() {
    header "Проверка IP (IP.Check.Place)"
    bash <(curl -Ls IP.Check.Place) -l en
    press_enter
}

do_test_bench_sh() {
    header "Параметры сервера и скорость (bench.sh)"
    wget -qO- bench.sh | bash
    press_enter
}

do_test_ip_quality_check() {
    header "IP Quality (Check.Place)"
    bash <(curl -Ls https://Check.Place) -EI
    press_enter
}

do_test_cpu_sysbench() {
    header "Тест производительности CPU"
    if ! command -v sysbench &>/dev/null; then
        info "Установка sysbench..."
        apt-get update -qq && apt-get install -y sysbench
    fi
    sysbench cpu run --threads=1
    press_enter
}

menu_tests() {
    while true; do
        clear
        header "Тесты и Бенчмарки"
        printf "${BLUE}─── Проверка IP и Блокировок ────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} Проверка региона IP\n"
        printf "${BOLD}  2)${NC} Censorcheck: Проверка геоблока\n"
        printf "${BOLD}  3)${NC} Censorcheck: Проверка DPI (РФ)\n"
        printf "${BOLD}  4)${NC} IP.Check.Place (English-info)\n"
        printf "${BOLD}  5)${NC} IPQuality (Check.Place)\n"
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

# ═══════════════════════════════════════════════════════════════
# 5. УСТАНОВКА BBR
# ═══════════════════════════════════════════════════════════════
do_install_bbr() {
    header "Установка TCP BBR"

    # ─── Проверка ядра ───
    local full major minor ver
    full="$(uname -r)"
    ver="$(echo "$full" | awk -F'-' '{print $1}' | awk -F. '{print $1"."$2}')"
    major="$(echo "$ver" | cut -d. -f1)"
    minor="$(echo "$ver" | cut -d. -f2)"

    info "Версия ядра: $full"

    if [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 9 ]; }; then
        info "Ядро поддерживает BBR."
    else
        error "Ядро старее 4.9 — BBR недоступен. Обновите ядро."
        press_enter
        return
    fi

    # ─── Контейнеризация ───
    local virt="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
    fi

    if [ -f /proc/user_beancounters ]; then
        warn "Обнаружен OpenVZ. Включение BBR может быть невозможно."
    fi

    case "$virt" in
        lxc|container|openvz|chroot|docker)
            warn "Контейнерная среда: $virt. Возможны ограничения." ;;
    esac

    # ─── BBR доступность ───
    local avail
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

    if ! echo "$avail" | grep -qw bbr; then
        info "BBR не найден, загружаю модуль tcp_bbr..."
        modprobe tcp_bbr 2>/dev/null || true
        avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
        if ! echo "$avail" | grep -qw bbr; then
            error "BBR недоступен даже после загрузки модуля."
            press_enter
            return
        fi
    fi

    info "BBR доступен: $avail"

    # ─── Применение ───
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr

    # ─── Persist ───
    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    mkdir -p /etc/sysctl.d
    cat >"$sysctl_file" <<EOF
# TCP BBR — created by setup.sh $(date +%Y%m%d%H%M%S)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true

    # ─── Проверка ───
    local cur
    cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [ "$cur" = "bbr" ]; then
        success "BBR успешно включён и активен."
    else
        warn "BBR не активен ($cur). Попробуйте перезагрузить сервер."
    fi
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 6. УСТАНОВКА ЛОГОВ
# ═══════════════════════════════════════════════════════════════
do_install_logs() {
    header "Установка системы логов"

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
    success "Logrotate настроен."

    # 4. Volume в docker-compose.yml
    if [ -f "$COMPOSE_FILE" ]; then
        cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
        if grep -q "/var/log/remnanode:/var/log/remnanode" "$COMPOSE_FILE"; then
            info "Volume для логов уже есть в docker-compose.yml."
        else
            info "Добавляю volume в docker-compose.yml..."
            if grep -E -q '^[ \t]+volumes:' "$COMPOSE_FILE"; then
                awk -v vol="      - \"/var/log/remnanode:/var/log/remnanode\"" '/^[ \t]+volumes:/ && !done { print; print vol; done=1; next } 1' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
            else
                sed -i '/SECRET_KEY/a \    volumes:\n      - "/var/log/remnanode:/var/log/remnanode"' "$COMPOSE_FILE"
            fi
            success "Volume добавлен."
        fi

        # 5. Рестарт
        info "Перезапуск контейнера..."
        cd "$REMNA_DIR" && docker compose down && docker compose up -d
        success "Контейнер перезапущен."
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

# ═══════════════════════════════════════════════════════════════
# 7. УСТАНОВКА WATCHDOG
# ═══════════════════════════════════════════════════════════════
do_install_watchdog() {
    header "Установка Watchdog (Xray Scan Detector)"

    # 1. Запрос параметров
    read -rp "$(printf "${CYAN}Введите имя ноды (NODE_NAME), напр. 🇳🇱 NL02_node: ${NC}")" node_name
    if [ -z "$node_name" ]; then
        error "NODE_NAME не может быть пустым!"
        press_enter
        return
    fi

    read -rp "$(printf "${CYAN}Введите Telegram Bot Token: ${NC}")" tg_bot_token
    if [ -z "$tg_bot_token" ]; then
        error "Bot Token не может быть пустым!"
        press_enter
        return
    fi

    read -rp "$(printf "${CYAN}Введите Telegram Chat ID: ${NC}")" tg_chat_id
    if [ -z "$tg_chat_id" ]; then
        error "Chat ID не может быть пустым!"
        press_enter
        return
    fi

    # 2. Зависимости
    info "Установка Python3 и pip..."
    apt-get update -qq
    apt-get install -y python3 python3-pip > /dev/null 2>&1
    pip3 install requests --break-system-packages > /dev/null 2>&1 || pip3 install requests > /dev/null 2>&1
    success "Зависимости установлены."

    # 3. config.py
    info "Создаю config.py..."
    cat > "${REMNA_DIR}/config.py" <<PYEOF
# ================= НАСТРОЙКИ =================
NODE_NAME = "${node_name}"
LOG_FILE = "/var/log/remnanode/access.log"

# Telegram
TG_BOT_TOKEN = "${tg_bot_token}"
TG_CHAT_ID = "${tg_chat_id}"

# 🎯 ПОРОГ СРАБАТЫВАНИЯ
SCORE_THRESHOLD = 800
SSH_UNIQUE_LIMIT = 50

# ⏳ Кулдаун
ALERT_COOLDOWN = 120

# ⚖️ БАЛЛЫ
POINTS_DOMAIN = 1       # 1 * 800 = 800 (Porog)
POINTS_IP = 3           # 3 * 266 = 800 (Porog)
POINTS_WHITELIST = 0    # 0 * 800 = 0 (Porog)
POINTS_SPAM = 100       # 100 * 8 = 800 (Porog)
POINTS_LOCAL_NET = 10   # 10 * 80 = 800 (Porog)

# 🛑 БЛОКИРОВКИ
SPAM_PORTS = ['25', '465', '587']
LOCAL_NETS = ['192.168.', '10.', '172.16.', '127.0.0.1', 'localhost']

# ✅ БЕЛЫЙ СПИСОК ДОМЕНОВ
WHITELIST = [
    'google', 'youtube', 'googlevideo', 'gmail', 'gstatic', 'doubleclick', 'android',
    'facebook', 'fbcdn', 'instagram', 'whatsapp', 'meta', 'cdninstagram',
    'apple', 'icloud', 'itunes', 'iphone', 'push.apple.com',
    'tiktok', 'tiktokcdn', 'tiktokv',
    'netflix', 'nflxvideo',
    'microsoft', 'windowsupdate', 'azure', 'office',
    'amazon', 'aws',
    'telegram', 'spotify', 'cloudflare',
    'yandex', 'ya.ru', 'kinopoisk', 'vk.com', 'ok.ru', 'vkuser', 'userapi', 'mail.ru',
    'steam', 'valve', 'epicgames', 'discord',
    'avito', 'ozon', 'wildberries', 'wb.ru',
    'openai', 'chatgpt', 'anthropic', 'claude', 'gemini', 'deepseek',
    'github', 'githubusercontent', 'copilot'
]

# 🛡️ ДОВЕРЕННЫЕ IP-ПОДСЕТИ
TRUSTED_IP_PREFIXES = [
    '149.154.', '91.108.', '5.28.', '91.105.', '95.161.',
    '2001:67c:', '2001:b28:',
    '173.194.', '74.125.', '142.250.', '142.251.',
    '162.159.', '199.103.', '35.214.',
    '104.16.', '104.17.', '104.18.', '104.19.', '104.20.', '104.21.',
    '172.64.', '172.67.', '199.232.',
    '92.223.', '185.106.',
    '87.240.', '95.163.', '93.186.'
]
# =============================================
PYEOF
    success "config.py создан с NODE_NAME = ${node_name}"

    # 4. scan_detector.py
    info "Создаю scan_detector.py..."
    cat > "${REMNA_DIR}/scan_detector.py" <<'PYEOF'
import time
import re
import os
import logging
import subprocess
import requests
from collections import deque, defaultdict
import config

# =============================================

logging.basicConfig(
    filename='/var/log/remnanode/scan_detector.log',
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)

user_scores = defaultdict(deque)
ssh_targets = defaultdict(list)
last_alert = {}

def send_telegram_msg(message):
    url = f"https://api.telegram.org/bot{config.TG_BOT_TOKEN}/sendMessage"
    try:
        data = {"chat_id": config.TG_CHAT_ID, "text": message, "parse_mode": "HTML", "disable_web_page_preview": True}
        requests.post(url, data=data, timeout=5)
    except Exception: pass

def send_telegram_file(filepath, caption):
    url = f"https://api.telegram.org/bot{config.TG_BOT_TOKEN}/sendDocument"
    try:
        with open(filepath, 'rb') as f:
            requests.post(url, data={"chat_id": config.TG_CHAT_ID, "caption": caption}, files={"document": f}, timeout=20)
    except Exception: pass

def extract_and_send_log(ip, user):
    clean_ip = re.sub(r'[^a-zA-Z0-9._-]', '_', ip)
    filename = f"/tmp/log_{clean_ip}.log"
    try:
        tail = subprocess.run(['tail', '-n', '10000', config.LOG_FILE], capture_output=True, text=True, timeout=10)
        grep = subprocess.run(['grep', ip], input=tail.stdout, capture_output=True, text=True, timeout=10)
        if grep.stdout.strip():
            lines = grep.stdout.strip().split('\n')
            last_lines = lines[-30:]
            preview = '\n'.join(last_lines)
            if len(preview) > 4000: preview = preview[-4000:]
            send_telegram_msg(f"📋 <b>Последние {len(last_lines)} строк</b> ({user}):\n\n<code>{preview}</code>")
            with open(filename, 'w') as f:
                f.write(grep.stdout)
            send_telegram_file(filename, f"📄 Полный лог: {user} ({ip}) — {len(lines)} строк")
            os.remove(filename)
    except Exception as e:
        logging.error(f"Ошибка извлечения лога для {ip}: {e}")

def is_ip_address(host):
    return re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", host) is not None

def is_trusted_ip(host):
    for prefix in config.TRUSTED_IP_PREFIXES:
        if host.startswith(prefix):
            return True
    return False

def cleanup_data(ip, now):
    dq = user_scores[ip]
    while dq and dq[0][0] < now - 60: dq.popleft()
    if not dq: del user_scores[ip]

    ssh_list = ssh_targets[ip]
    ssh_targets[ip] = [x for x in ssh_list if x[0] > now - 60]
    if not ssh_targets[ip]: del ssh_targets[ip]

    expired = [k for k, v in last_alert.items() if now - v > 3600]
    for k in expired:
        del last_alert[k]

    max_entries = 10000
    if len(last_alert) > max_entries:
        oldest = sorted(last_alert.items(), key=lambda x: x[1])[:max_entries//10]
        for k, _ in oldest:
            del last_alert[k]

def calculate_current_score(ip):
    return sum(points for _, points in user_scores[ip])

def get_unique_ssh_count(ip):
    if ip not in ssh_targets: return 0
    return len({target for _, target in ssh_targets[ip]})

def get_score_breakdown(ip):
    breakdown = defaultdict(lambda: {"count": 0, "total": 0})
    for _, points in user_scores[ip]:
        if points == config.POINTS_SPAM:
            cat = "📧 Спам (Почта)"
        elif points == config.POINTS_LOCAL_NET:
            cat = "🕵️ Локальная сеть"
        elif points == config.POINTS_IP:
            cat = "🌐 IP-трафик"
        elif points == config.POINTS_DOMAIN:
            cat = "🔗 Домен-трафик"
        else:
            cat = "❓ Другое"
        breakdown[cat]["count"] += 1
        breakdown[cat]["total"] += points

    lines = []
    for cat, data in sorted(breakdown.items(), key=lambda x: x[1]["total"], reverse=True):
        lines.append(f"  {cat}: {data['count']} шт. (+{data['total']})")
    return "\n".join(lines)

def process_request(ip, user, dest):
    now = time.time()
    if ip in last_alert and now - last_alert[ip] < config.ALERT_COOLDOWN: return

    clean_dest = dest.replace("tcp:", "").replace("udp:", "")
    try: host, port = clean_dest.rsplit(':', 1)
    except ValueError: host = clean_dest; port = ""

    reason = ""; is_critical = False; points = 0
    is_pure_ip = is_ip_address(host)

    if port == '22':
        ssh_targets[ip].append((now, host))
        if get_unique_ssh_count(ip) > config.SSH_UNIQUE_LIMIT:
            reason = f"🔓 <b>Скан SSH (Brute-force)</b>\n> {config.SSH_UNIQUE_LIMIT} серверов."; is_critical = True

    if not is_critical:
        if port in config.SPAM_PORTS:
            points = config.POINTS_SPAM

    if not is_critical and is_pure_ip and points == 0:
        for net in config.LOCAL_NETS:
            if host.startswith(net):
                points = config.POINTS_LOCAL_NET
                break

    is_whitelisted = False
    if not is_critical and points == 0:
        if port in ['53', '853']: return

        for w in config.WHITELIST:
            if w in host.lower(): is_whitelisted = True; points = config.POINTS_WHITELIST; break

        if not is_whitelisted and is_pure_ip and is_trusted_ip(host):
             is_whitelisted = True; points = config.POINTS_WHITELIST

    if not is_critical and not is_whitelisted and points == 0:
        points = config.POINTS_IP if is_pure_ip else config.POINTS_DOMAIN

    if points > 0: user_scores[ip].append((now, points))
    cleanup_data(ip, now)
    current_score = calculate_current_score(ip)

    if current_score >= config.SCORE_THRESHOLD and not reason:
        breakdown = get_score_breakdown(ip)
        reason = (f"🚀 <b>Подозрительный трафик</b>\n"
                  f"Баллы: <b>{current_score}</b> (Лимит: {config.SCORE_THRESHOLD})\n"
                  f"\n<b>Разбивка:</b>\n{breakdown}")

    if reason or is_critical:
        extra_info = ""
        if "SSH" in reason:
            unique_hosts = list({target for _, target in ssh_targets[ip]})[:5]
            extra_info = f"\nЦели: {', '.join(unique_hosts)}..."

        user_display = user if user else "unknown"
        msg = (f"🚨 <b>XRAY ALERT</b> [{config.NODE_NAME}]\n\n👤 <b>User:</b> {user_display}\n"
               f"🌐 <b>IP:</b> <code>{ip}</code>\n🎯 <b>Цель:</b> <code>{host}:{port}</code>\n"
               f"{reason}{extra_info}\n\n⬇️ <i>Лог файл прикреплен ниже</i>")

        logging.info(f"ALARM: {ip} -> {reason}")
        send_telegram_msg(msg)
        extract_and_send_log(ip, user_display)

        last_alert[ip] = now
        user_scores[ip].clear(); ssh_targets[ip].clear()

def monitor_log():
    while True:
        try:
            logging.info("Запуск мониторинга лога...")
            p = subprocess.Popen(['tail', '-F', config.LOG_FILE], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            while True:
                line = p.stdout.readline()
                if not line: time.sleep(0.1); continue
                if "accepted" in line:
                    try:
                        parts = line.split()
                        ip_part = ""; dest_part = ""; user_part = "unknown"
                        for i, part in enumerate(parts):
                            if part == "accepted":
                                ip_part = parts[i-1].split(':')[0]; dest_part = parts[i+1]; break
                        if "email:" in line: user_part = line.split("email:")[-1].strip()
                        if ip_part and dest_part and ip_part not in ["127.0.0.1", "::1"]:
                            process_request(ip_part, user_part, dest_part)
                    except Exception: pass
        except Exception as e:
            logging.error(f"monitor_log упал: {e}")
            time.sleep(5)

if __name__ == "__main__":
    monitor_log()
PYEOF
    success "scan_detector.py создан."

    # 5. Systemd сервис
    info "Создаю службу systemd..."
    cat > /etc/systemd/system/xray-watchdog.service <<EOF
[Unit]
Description=Xray Log Watchdog
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${REMNA_DIR}
ExecStart=/usr/bin/python3 ${REMNA_DIR}/scan_detector.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 6. Запуск
    systemctl daemon-reload
    systemctl enable xray-watchdog
    systemctl restart xray-watchdog

    echo ""
    info "Статус службы:"
    systemctl status xray-watchdog --no-pager || true

    success "Watchdog установлен и запущен! NODE_NAME = ${node_name}"
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 8. УСТАНОВКА BESZEL AGENT
# ═══════════════════════════════════════════════════════════════
do_install_beszel() {
    header "Установка Beszel Agent"

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

# ═══════════════════════════════════════════════════════════════
# 9. УПРАВЛЕНИЕ CLOUDFLARE WARP
# ═══════════════════════════════════════════════════════════════

do_uninstall_warp() {
    header "Удаление Cloudflare WARP"
    info "Остановка интерфейса warp..."
    if ip link show warp &>/dev/null; then
        wg-quick down warp &>/dev/null || true
    fi
    systemctl disable wg-quick@warp &>/dev/null || true
    
    info "Удаление файлов и пакетов..."
    rm -f /etc/wireguard/warp.conf
    rm -f /usr/local/bin/wgcf
    rm -f wgcf-account.toml wgcf-profile.conf
    
    # Пакет wireguard удаляем только если пользователь уверен (может использоваться другими)
    read -rp "$(printf "${YELLOW}Удалить пакет wireguard? [y/N]: ${NC}")" rm_wg
    if [[ "$rm_wg" =~ ^[Yy]$ ]]; then
        apt-get remove --purge -y wireguard
        apt-get autoremove -y
    fi
    
    success "Cloudflare WARP удален."
    press_enter
}

do_install_warp() {
    header "Установка Cloudflare WARP"

    # 1. Проверка установки
    if command -v wgcf >/dev/null 2>&1 && [ -f "/etc/wireguard/warp.conf" ]; then
        warn "WARP уже установлен."
        read -rp "$(printf "${YELLOW}Переустановить? [y/N]: ${NC}")" reinst
        if [[ ! "$reinst" =~ ^[Yy]$ ]]; then return; fi
        do_uninstall_warp
    fi

    # 2. Установка WireGuard
    info "Установка WireGuard..."
    apt-get update -qq && apt-get install -y wireguard wget curl jq
    
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
        header "Управление Cloudflare WARP"
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

# ═══════════════════════════════════════════════════════════════
# 9.5 TRAFFICGUARD PRO MANAGER
# ═══════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════
# 8. ПОЛНАЯ УСТАНОВКА
# ═══════════════════════════════════════════════════════════════
do_full_install() {
    header "Полная установка"
    printf "${BOLD}${YELLOW}Будут выполнены следующие шаги:${NC}\n"
    echo "  1. Обновление системы (APT)"
    echo "  2. Установка TCP BBR"
    echo "  3. Настройка UFW: Запрет пинга (ICMP DROP)"
    echo "  4. Настройка UFW: Включение + SSH + Rate Limit"
    echo "  5. Настройка UFW: Открытие порта 443/tcp"
    echo "  6. Установка ноды (Docker + Compose)"
    echo "  7. Настройка логов (Logrotate)"
    echo "  8. Установка Watchdog"
    echo "  9. Установка Beszel Agent"
    echo ""
    read -rp "$(printf "${CYAN}Продолжить? [y/N]: ${NC}")" confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Отменено."
        press_enter
        return
    fi

    # 1. Обновление
    do_update
    
    # 2. BBR
    do_install_bbr
    
    # 3. ICMP DROP
    info "Настройка ICMP DROP..."
    ufw_disable_ping
    
    # 4. UFW Secure
    ufw_enable_secure
    
    # 5. Port 443
    info "Открытие порта 443/tcp..."
    ufw allow 443/tcp
    
    # 6. Нода
    do_install_node
    
    # 7. Логи
    do_install_logs
    
    # 8. Watchdog
    do_install_watchdog
    
    # 9. Beszel
    do_install_beszel

    header "Полная установка завершена!"
    success "Все компоненты настроены."
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# ГЛАВНОЕ МЕНЮ
# ═══════════════════════════════════════════════════════════════
main_menu() {
    while true; do
        clear
        printf "${CYAN}"
        echo "  ┌─────────────────────────────────────────────┐"
        echo "  │                                             │"
        echo "  │       🚀  QUICK INSTALL — Setup Tool        │"
        echo "  │                                             │"
        echo "  └─────────────────────────────────────────────┘"
        printf "${NC}\n"

        printf "${BLUE}─── Система и Оптимизация ───────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} 📦  Обновление системы (APT upgrade)\n"
        printf "${BOLD}  2)${NC} ⚡  Установка TCP BBR (Ускорение сети)\n"
        echo ""
        printf "${BLUE}─── Управление Сервисами ────────────────────────────${NC}\n"
        printf "${BOLD}  3)${NC} 🐳  Управление Нодой\n"
        printf "${BOLD}  4)${NC} 📊  Установка Beszel Agent\n"
        printf "${BOLD}  7)${NC} 🧪  Тесты и Бенчмарки\n"
        echo ""
        printf "${BLUE}─── Безопасность ────────────────────────────────────${NC}\n"
        printf "${BOLD}  5)${NC} 🔥  Настройка Фаервола (UFW)\n"
        printf "${BOLD}  6)${NC} ☁️  Cloudflare WARP (VPN для сервера)\n"
        printf "${BOLD}  8)${NC} 🛡️  Trafficguard Pro Manager\n"
        echo ""
        printf "${BLUE}─── Автоматизация ───────────────────────────────────${NC}\n"
        printf "${BOLD} 10)${NC} 🔧  ПОЛНАЯ УСТАНОВКА (Система + UFW + Нода + Безель)\n"
        echo ""
        printf "${BOLD}  0)${NC} ❌  Выход\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_update ;;
            2) do_install_bbr ;;
            3) menu_node ;;
            4) do_install_beszel ;;
            5) menu_ufw ;;
            6) menu_warp ;;
            7) menu_tests ;;
            8) do_trafficguard ;;
            10) do_full_install ;;
            0) echo ""; info "До свидания!"; exit 0 ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

# ─── Точка входа ─────────────────────────────────────────────
require_root
main_menu
