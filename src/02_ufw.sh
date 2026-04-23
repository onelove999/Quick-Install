#!/usr/bin/env bash

# ─── Функции статуса ─────────────────────────────────────────

get_icmp_status() {
    local rules_file="/etc/ufw/before.rules"
    if [ ! -f "$rules_file" ]; then
        printf "${RED}(Файл не найден)${NC}"
        return
    fi
    if grep -q "\-A ufw-before-input -p icmp --icmp-type echo-request -j DROP" "$rules_file"; then
        printf "${RED}(Запрещены)${NC}"
    else
        printf "${GREEN}(Разрешены)${NC}"
    fi
}

ufw_enable_secure() {
    header "Включение UFW (Безопасное)" "Безопасность"
    
    warn "Это действие включит фаервол и разрешит доступ по SSH."
    read -rp "$(printf "${YELLOW}Продолжить? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

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
    header "Простое включение UFW" "Безопасность"
    
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
    header "Выключение UFW" "Безопасность"
    read -rp "$(printf "${YELLOW}Вы уверены, что хотите полностью выключить фаервол? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi
    ufw disable
    success "UFW выключен."
    press_enter
}

ufw_open_port() {
    header "Открытие порта" "Безопасность > UFW"
    local port
    while true; do
        read -rp "Введите порт (или диапазон, напр. 8000:8100): " port
        if [ -z "$port" ]; then info "Отменено."; return; fi
        if is_valid_port "${port%%:*}"; then break; else error "Неверный формат порта!"; fi
    done
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
    header "Открытие порта для конкретного IP" "Безопасность > UFW"
    local ip port
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
    ufw allow from "$ip" to any port "$port" proto "$proto"
    success "Порт $port открыт для IP $ip ($proto)."
    press_enter
}

ufw_close_port() {
    header "Закрытие порта" "Безопасность > UFW"
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
    header "Закрытие порта для конкретного IP" "Безопасность > UFW"
    read -rp "Введите IP-адрес: " ip
    read -rp "Введите порт: " port
    read -rp "Протокол [tcp/udp] (Enter = tcp): " proto
    proto=${proto:-tcp}
    ufw deny from "$ip" to any port "$port" proto "$proto"
    success "Порт $port закрыт для IP $ip ($proto)."
    press_enter
}

set_icmp_rules() {
    local file="$1" action="$2"  # action = DROP или ACCEPT

    # 1. Удаляем ВСЕ существующие ICMP-правила (и DROP и ACCEPT) из обеих секций
    sed -i '/-A ufw-before-input -p icmp --icmp-type .* -j \(ACCEPT\|DROP\)/d' "$file"
    sed -i '/-A ufw-before-forward -p icmp --icmp-type .* -j \(ACCEPT\|DROP\)/d' "$file"

    # 2. Вставляем INPUT правила после якоря
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
    header "Отключение ICMP (Ping)" "Безопасность > UFW"
    
    info "Текущий статус: $(get_icmp_status)"
    warn "Отключение ответов на пинг сделает сервер 'невидимым' для простых проверок."
    echo ""
    read -rp "$(printf "${YELLOW}Отключить ответы на пинг (icmp-type echo-request -> DROP)? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

    local rules_file="/etc/ufw/before.rules"
    if [ ! -f "$rules_file" ]; then error "Файл конфигурации не найден!"; press_enter; return; fi

    cp "$rules_file" "${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    info "Бэкап конфигурации создан."

    measure_time set_icmp_rules "$rules_file" "DROP"
    ufw reload >/dev/null 2>&1
    success "Конфигурация обновлена. Пинги теперь ИГНОРИРУЮТСЯ."
    press_enter
}

ufw_enable_ping() {
    header "Включение ICMP (Ping)" "Безопасность > UFW"

    info "Текущий статус: $(get_icmp_status)"
    echo ""
    read -rp "$(printf "${YELLOW}Включить ответы на пинг (icmp-type echo-request -> ACCEPT)? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

    local rules_file="/etc/ufw/before.rules"
    if [ ! -f "$rules_file" ]; then error "Файл конфигурации не найден!"; press_enter; return; fi

    cp "$rules_file" "${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    info "Бэкап конфигурации создан."

    measure_time set_icmp_rules "$rules_file" "ACCEPT"
    ufw reload >/dev/null 2>&1
    success "Конфигурация обновлена. Пинги теперь РАЗРЕШЕНЫ."
    press_enter
}

ufw_status() {
    header "Статус UFW" "Безопасность > UFW"
    ufw status numbered verbose
    press_enter
}

ufw_delete_rule() {
    header "Удаление правила UFW" "Безопасность > UFW"
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
        header "Управление UFW" "Безопасность"
        
        printf "${BLUE}─── Состояние: $(get_ufw_status) ──────── ICMP: $(get_icmp_status) ──${NC}\n"
        printf "${BOLD}  1)${NC} Статус UFW (подробно)\n"
        printf "${BOLD}  2)${NC} Включить UFW (Базово)\n"
        printf "${BOLD}  3)${NC} Включить UFW (Рекомендуется)\n"
        printf "${BOLD}  4)${NC} Выключить UFW\n"
        echo ""
        printf "${BLUE}─── Пинги (ICMP) ────────────────────────────────────${NC}\n"
        printf "${BOLD}  9)${NC} Запретить ответы на пинг\n"
        printf "${BOLD} 10)${NC} Разрешить ответы на пинг\n"
        echo ""
        printf "${BLUE}─── Управление портами ──────────────────────────────${NC}\n"
        printf "${BOLD}  5)${NC} Открыть порт (TCP/UDP)\n"
        printf "${BOLD}  6)${NC} Открыть порт для IP\n"
        printf "${BOLD}  7)${NC} Закрыть порт\n"
        printf "${BOLD}  8)${NC} Удалить правило по номеру\n"
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

