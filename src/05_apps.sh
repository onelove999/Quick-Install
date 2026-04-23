#!/usr/bin/env bash

do_install_vpnguard() {
    header "Установка / Обновление VPN Guard"

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
    offer_disable_legacy_watchdog

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
    header "Запуск VPN Guard"
    compose_vpnguard up -d
    press_enter
}

do_stop_vpnguard() {
    header "Остановка VPN Guard"
    compose_vpnguard stop
    press_enter
}

do_restart_vpnguard() {
    header "Перезапуск VPN Guard"
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
        printf "${BOLD}  6)${NC} 📝 Редактировать конфиг вручную (nano)\n"
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
        printf "${BOLD}  8)${NC} ⚙️  Настройки VPN Guard\n"
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

offer_disable_legacy_watchdog() {
    if [ -f "/etc/systemd/system/xray-watchdog.service" ]; then
        warn "Обнаружен legacy watchdog (xray-watchdog.service)."
        read -rp "$(printf "${YELLOW}Остановить и отключить старый watchdog сейчас? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            systemctl stop xray-watchdog 2>/dev/null || true
            systemctl disable xray-watchdog 2>/dev/null || true
            success "Legacy watchdog остановлен и отключен."
        fi
    fi
}

do_install_watchdog() {
    header "Установка Watchdog (Xray Scan Detector)"

    # 0. Проверка существующей установки
    if [ -f "/etc/systemd/system/xray-watchdog.service" ] || [ -f "${REMNA_DIR}/scan_detector.py" ]; then
        warn "Watchdog уже установлен."
        read -rp "$(printf "${YELLOW}Вы уверены, что хотите переустановить Watchdog? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    else
        read -rp "$(printf "${YELLOW}Установить Watchdog (детектор сканирований)? [y/N]: ${NC}")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Установка отменена."
            press_enter
            return
        fi
    fi

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

do_disable_watchdog() {
    header "Отключение legacy watchdog"
    if [ ! -f "/etc/systemd/system/xray-watchdog.service" ]; then
        warn "Служба xray-watchdog.service не найдена."
        press_enter
        return
    fi

    systemctl stop xray-watchdog 2>/dev/null || true
    systemctl disable xray-watchdog 2>/dev/null || true
    success "Legacy watchdog остановлен и отключен."
    press_enter
}

do_remove_watchdog() {
    header "Удаление legacy watchdog"
    read -rp "$(printf "${YELLOW}Удалить службу xray-watchdog и Python-файлы watchdog? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Удаление отменено."
        press_enter
        return
    fi

    systemctl stop xray-watchdog 2>/dev/null || true
    systemctl disable xray-watchdog 2>/dev/null || true
    rm -f /etc/systemd/system/xray-watchdog.service
    systemctl daemon-reload
    rm -f "${REMNA_DIR}/scan_detector.py" "${REMNA_DIR}/config.py"
    success "Legacy watchdog удален."
    press_enter
}

menu_watchdog_legacy() {
    while true; do
        clear
        header "Legacy Watchdog"
        printf "${BOLD}  1)${NC} Установить / переустановить старый Watchdog\n"
        printf "${BOLD}  2)${NC} Отключить службу Watchdog\n"
        printf "${BOLD}  3)${NC} Полностью удалить Watchdog\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_watchdog ;;
            2) do_disable_watchdog ;;
            3) do_remove_watchdog ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

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
    header "Установка AdGuard Home"

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

menu_monitoring() {
    while true; do
        clear
        header "Мониторинг" "Главное меню"
        printf "${BOLD}  1)${NC} Beszel Agent (Панель мониторинга)\n"
        printf "${BOLD}  2)${NC} VPN Guard (Docker + Аналитика)\n"
        printf "${BOLD}  3)${NC} Legacy Watchdog\n"
        printf "${BOLD}  4)${NC} Настройка ротации логов (Logrotate)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_install_beszel ;;
            2) menu_vpnguard ;;
            3) menu_watchdog_legacy ;;
            4) do_install_logs ;;
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

menu_tests() {
    while true; do
        clear
        header "Тесты и Бенчмарки" "Главное меню"
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

