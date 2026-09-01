#!/usr/bin/env bash

# ─── Функции статуса ─────────────────────────────────────────

ensure_ufw() {
    if command -v ufw &>/dev/null; then
        return 0
    fi
    warn "UFW не установлен."
    if command -v apt-get &>/dev/null && confirm_action "Установить пакет ufw"; then
        apt-get update -qq && apt-get install -y ufw && return 0
    fi
    error "Без UFW действие невозможно."
    press_enter
    return 1
}

get_icmp_status() {
    local rules_file="/etc/ufw/before.rules"
    if [ ! -f "$rules_file" ]; then
        printf "${RED}(Файл не найден)${NC}"
        return
    fi
    if grep -q -- "^-A ufw-before-input -p icmp --icmp-type echo-request -j DROP$" "$rules_file"; then
        printf "${RED}(Запрещены)${NC}"
    else
        printf "${GREEN}(Разрешены)${NC}"
    fi
}

ufw_enable_secure() {
    header "Включение UFW (Безопасное)" "Безопасность"
    ensure_ufw || return
    
    warn "Это действие включит фаервол и разрешит доступ по SSH."
    if ! confirm_action "Продолжить"; then
        info "Отменено."
        press_enter
        return
    fi

    local ssh_port
    while IFS= read -r ssh_port; do
        is_valid_port "$ssh_port" || continue
        info "Разрешаем активный SSH-порт ${ssh_port}/tcp..."
        ufw allow "${ssh_port}/tcp" || { error "Не удалось добавить SSH-правило."; press_enter; return 1; }
        info "Добавляем rate limit для ${ssh_port}/tcp..."
        ufw limit "${ssh_port}/tcp" || { error "Не удалось добавить SSH rate limit."; press_enter; return 1; }
    done < <(get_sshd_ports)
    info "Включаем UFW..."
    ufw --force enable || { error "Не удалось включить UFW."; press_enter; return 1; }
    success "UFW включён. OpenSSH разрешён."
    ufw status verbose
    press_enter
}

ufw_enable_basic() {
    header "Простое включение UFW" "Безопасность"
    ensure_ufw || return
    
    # ПРОВЕРКА SSH
    local ssh_port missing_ssh=0
    while IFS= read -r ssh_port; do
        if ! ufw status | grep -qE "^${ssh_port}(/tcp)?[[:space:]]+ALLOW|OpenSSH[[:space:]]+ALLOW"; then
            missing_ssh=1
            warn "ВНИМАНИЕ: разрешающее правило для SSH-порта ${ssh_port}/tcp не найдено."
        fi
    done < <(get_sshd_ports)
    if [ "$missing_ssh" -eq 1 ]; then
        warn "Включение UFW может привести к потере доступа по SSH."
        echo ""
        if ! confirm_action "Вы уверены, что хотите продолжить"; then
            info "Включение отменено."
            press_enter
            return
        fi
    fi

    info "Включаем UFW..."
    ufw --force enable || { error "Не удалось включить UFW."; press_enter; return 1; }
    success "UFW включён (без добавления новых правил)."
    ufw status verbose
    press_enter
}

ufw_disable() {
    header "Выключение UFW" "Безопасность"
    ensure_ufw || return
    if ! confirm_action "Вы уверены, что хотите полностью выключить фаервол"; then
        info "Отменено."
        press_enter
        return
    fi
    ufw disable || { error "Не удалось выключить UFW."; press_enter; return 1; }
    success "UFW выключен."
    press_enter
}

ufw_open_port() {
    header "Открытие порта" "Безопасность > UFW"
    ensure_ufw || return
    local port proto
    while true; do
        read -rp "Введите порт (или диапазон, напр. 8000:8100): " port
        if [ -z "$port" ]; then info "Отменено."; return; fi
        if is_valid_port_spec "$port"; then break; else error "Неверный порт или диапазон!"; fi
    done
    read -rp "Протокол [tcp/udp/any] (Enter = any): " proto
    proto=${proto:-any}
    if ! is_valid_protocol "$proto"; then error "Допустимы только tcp, udp или any."; press_enter; return 1; fi
    if [ -z "$proto" ] || [ "$proto" = "any" ]; then
        ufw allow "$port" || { error "Не удалось открыть порт."; press_enter; return 1; }
    else
        ufw allow "$port/$proto" || { error "Не удалось открыть порт."; press_enter; return 1; }
    fi
    success "Порт $port открыт."
    press_enter
}

ufw_open_port_ip() {
    header "Открытие порта для конкретного IP" "Безопасность > UFW"
    ensure_ufw || return
    local ip port proto
    while true; do
        read -rp "Введите IP-адрес: " ip
        if is_valid_ip "$ip"; then break; else error "Неверный формат IP!"; fi
    done
    while true; do
        read -rp "Введите порт: " port
        if is_valid_port "$port"; then break; else error "Неверный формат порта!"; fi
    done
    read -rp "Протокол [tcp/udp] (Enter = tcp): " proto
    proto=${proto:-tcp}
    if ! is_valid_protocol "$proto" || [ "$proto" = "any" ]; then error "Допустимы только tcp или udp."; press_enter; return 1; fi
    ufw allow from "$ip" to any port "$port" proto "$proto" || { error "Не удалось добавить правило."; press_enter; return 1; }
    success "Порт $port открыт для IP $ip ($proto)."
    press_enter
}

ufw_close_port() {
    header "Закрытие порта" "Безопасность > UFW"
    ensure_ufw || return
    local port proto
    read -rp "Введите порт (или диапазон): " port
    if ! is_valid_port_spec "$port"; then error "Неверный порт или диапазон."; press_enter; return 1; fi
    read -rp "Протокол [tcp/udp/any] (Enter = any): " proto
    proto=${proto:-any}
    if ! is_valid_protocol "$proto"; then error "Допустимы только tcp, udp или any."; press_enter; return 1; fi
    if [ -z "$proto" ] || [ "$proto" = "any" ]; then
        ufw --force delete allow "$port" || { error "Разрешающее правило для $port не найдено."; press_enter; return 1; }
    else
        ufw --force delete allow "$port/$proto" || { error "Разрешающее правило для $port/$proto не найдено."; press_enter; return 1; }
    fi
    success "Порт $port закрыт."
    press_enter
}

ufw_close_port_ip() {
    header "Закрытие порта для конкретного IP" "Безопасность > UFW"
    ensure_ufw || return
    local ip port proto
    read -rp "Введите IP-адрес: " ip
    if ! is_valid_ip "$ip"; then error "Неверный IP-адрес."; press_enter; return 1; fi
    read -rp "Введите порт: " port
    if ! is_valid_port "$port"; then error "Неверный порт."; press_enter; return 1; fi
    read -rp "Протокол [tcp/udp] (Enter = tcp): " proto
    proto=${proto:-tcp}
    if ! is_valid_protocol "$proto" || [ "$proto" = "any" ]; then error "Допустимы только tcp или udp."; press_enter; return 1; fi
    ufw --force delete allow from "$ip" to any port "$port" proto "$proto" || {
        error "Соответствующее разрешающее правило не найдено."
        press_enter
        return 1
    }
    success "Порт $port закрыт для IP $ip ($proto)."
    press_enter
}

set_icmp_rules() {
    local file="$1" action="$2"
    local input_anchor="# ok icmp codes for INPUT"
    if grep -qE '^-A ufw-before-input -p icmp --icmp-type echo-request -j (ACCEPT|DROP)$' "$file"; then
        sed -i -E "s|^(-A ufw-before-input -p icmp --icmp-type echo-request -j) (ACCEPT|DROP)$|\\1 ${action}|" "$file"
    elif grep -qF "$input_anchor" "$file"; then
        sed -i "/${input_anchor}/a\\-A ufw-before-input -p icmp --icmp-type echo-request -j ${action}" "$file"
    else
        error "Не найден блок INPUT ICMP в $file."
        return 1
    fi
}

ufw_disable_ping() {
    header "Отключение ICMP (Ping)" "Безопасность > UFW"
    
    info "Текущий статус: $(get_icmp_status)"
    warn "Отключение ответов на пинг сделает сервер 'невидимым' для простых проверок."
    echo ""
    ensure_ufw || return
    if ! confirm_action "Отключить только echo-request (ping)"; then
        info "Отменено."
        press_enter
        return
    fi

    local rules_file="/etc/ufw/before.rules"
    if [ ! -f "$rules_file" ]; then error "Файл конфигурации не найден!"; press_enter; return; fi

    local backup="${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$rules_file" "$backup"
    info "Бэкап конфигурации создан."

    if ! measure_time set_icmp_rules "$rules_file" "DROP" || ! ufw reload >/dev/null 2>&1; then
        cp -p "$backup" "$rules_file"
        ufw reload >/dev/null 2>&1 || true
        error "Изменение не применено; исходный файл восстановлен."
        press_enter
        return 1
    fi
    success "Конфигурация обновлена. Пинги теперь ИГНОРИРУЮТСЯ."
    press_enter
}

ufw_enable_ping() {
    header "Включение ICMP (Ping)" "Безопасность > UFW"

    info "Текущий статус: $(get_icmp_status)"
    echo ""
    ensure_ufw || return
    if ! confirm_action "Включить ответы на ping"; then
        info "Отменено."
        press_enter
        return
    fi

    local rules_file="/etc/ufw/before.rules"
    if [ ! -f "$rules_file" ]; then error "Файл конфигурации не найден!"; press_enter; return; fi

    local backup="${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$rules_file" "$backup"
    info "Бэкап конфигурации создан."

    if ! measure_time set_icmp_rules "$rules_file" "ACCEPT" || ! ufw reload >/dev/null 2>&1; then
        cp -p "$backup" "$rules_file"
        ufw reload >/dev/null 2>&1 || true
        error "Изменение не применено; исходный файл восстановлен."
        press_enter
        return 1
    fi
    success "Конфигурация обновлена. Пинги теперь РАЗРЕШЕНЫ."
    press_enter
}

ufw_status() {
    header "Статус UFW" "Безопасность > UFW"
    ensure_ufw || return
    ufw status numbered verbose
    press_enter
}

ufw_delete_rule() {
    header "Удаление правила UFW" "Безопасность > UFW"
    ensure_ufw || return
    ufw status numbered
    echo ""
    read -rp "Введите номер правила для удаления (или 0 для отмены): " rule_num
    if [ "$rule_num" != "0" ] && [ -n "$rule_num" ]; then
        if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then error "Номер должен быть целым числом."; press_enter; return 1; fi
        ufw --force delete "$rule_num" || { error "Не удалось удалить правило #$rule_num."; press_enter; return 1; }
        success "Правило #$rule_num удалено."
    fi
    press_enter
}

menu_ufw() {
    while true; do
        clear
        header "Управление UFW" "Безопасность"
        
        menu_section "UFW: $(get_ufw_status) · Ping: $(get_icmp_status)"
        menu_item 1 "Показать подробный статус"
        menu_item 2 "Включить без изменения правил"
        menu_item 3 "Включить безопасно (с SSH-правилом)"
        menu_item 4 "Выключить UFW"
        echo ""
        menu_section "Ping (ICMP echo-request)"
        menu_item 5 "Запретить ответы на ping"
        menu_item 6 "Разрешить ответы на ping"
        echo ""
        menu_section "Правила доступа"
        menu_item 7 "Открыть порт"
        menu_item 8 "Открыть порт для IPv4"
        menu_item 9 "Удалить разрешение порта"
        menu_item 10 "Удалить правило по номеру"
        menu_item 11 "Удалить разрешение порта для IPv4"
        menu_back
        read_choice choice

        case "$choice" in
            1) ufw_status ;;
            2) ufw_enable_basic ;;
            3) ufw_enable_secure ;;
            4) ufw_disable ;;
            5) ufw_disable_ping ;;
            6) ufw_enable_ping ;;
            7) ufw_open_port ;;
            8) ufw_open_port_ip ;;
            9) ufw_close_port ;;
            10) ufw_delete_rule ;;
            11) ufw_close_port_ip ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}
