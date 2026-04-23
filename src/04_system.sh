#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ═══════════════════════════════════════════════════════════════
do_update() {
    header "Обновление системы" "Система"
    
    local os_desc=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    info "Текущая система: ${BOLD}${os_desc}${NC}"
    info "Запрашиваю список обновлений (apt update)..."
    
    measure_time apt-get update -qq
    
    local updatable=$(apt list --upgradable 2>/dev/null | grep -c "\[upgradable from:\|может быть обновлен" || echo "0")
    
    if [ "$updatable" -gt 0 ]; then
        warn "Найдено пакетов для обновления: ${BOLD}${updatable}${NC}"
    else
        success "Система уже в актуальном состоянии."
    fi

    echo ""
    read -rp "$(printf "${YELLOW}Выполнить полное обновление (apt upgrade)? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Обновление отменено."
        press_enter
        return
    fi

    info "Запуск обновления пакетов..."
    measure_time apt-get upgrade -y
    
    success "Обновление завершено."
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 2. УСТАНОВКА TCP BBR
# ═══════════════════════════════════════════════════════════════
do_install_bbr() {
    header "Установка TCP BBR" "Система"

    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local kernel_ver=$(uname -r)

    info "Текущее ядро: ${BOLD}${kernel_ver}${NC}"
    info "Алгоритм (Congestion Control): ${BOLD}${cur_cc}${NC}"
    info "Очередь (Default Qdisc):      ${BOLD}${cur_qdisc}${NC}"

    if [ "$cur_cc" = "bbr" ]; then
        success "Вердикт: BBR уже активен и используется."
    else
        warn "Вердикт: BBR не активен (установлен $cur_cc)."
    fi

    echo ""
    printf "Доступные действия:\n"
    if [ "$cur_cc" = "bbr" ]; then
        printf "${BOLD}  1)${NC} Обновить / Переустановить конфиг BBR\n"
        printf "${BOLD}  2)${NC} ${RED}Отключить BBR${NC} (вернуть cubic)\n"
    else
        printf "${BOLD}  1)${NC} Включить TCP BBR (Рекомендуется)\n"
    fi
    printf "${BOLD}  0)${NC} ← Назад\n"
    echo ""
    read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" bbr_choice

    case "$bbr_choice" in
        1)
            info "Настройка BBR..."
            measure_time bash -c "
                modprobe tcp_bbr 2>/dev/null || true
                sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
                sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
                mkdir -p /etc/sysctl.d
                echo 'net.core.default_qdisc = fq' > $sysctl_file
                echo 'net.ipv4.tcp_congestion_control = bbr' >> $sysctl_file
                sysctl --system >/dev/null 2>&1
            "
            success "Конфигурация BBR успешно применена."
            ;;
        2)
            if [ "$cur_cc" = "bbr" ]; then
                info "Отключение BBR..."
                measure_time bash -c "
                    rm -f $sysctl_file
                    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
                    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
                    sysctl --system >/dev/null 2>&1
                "
                success "BBR отключен, система возвращена к стандартным настройкам."
            fi
            ;;
        0|*) return ;;
    esac
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 3. НАСТРОЙКА SWAP
# ═══════════════════════════════════════════════════════════════
do_setup_swap() {
    header "Настройка SWAP" "Система"
    
    info "Текущее состояние SWAP (swapon):"
    local swap_info=$(swapon --show --noheadings)
    if [ -n "$swap_info" ]; then
        echo "$swap_info"
    else
        warn "Активные файлы подкачки не найдены."
    fi

    local ram_total=$(free -h | awk '/Mem:/ {print $2}')
    local swap_total=$(free -h | awk '/Swap:/ {print $2}')
    
    info "Память (RAM): ${BOLD}${ram_total}${NC} | SWAP: ${BOLD}${swap_total}${NC}"
    
    if [ "$(free | awk '/Swap:/ {print $2}')" -gt 0 ]; then
        success "Вердикт: SWAP настроен и активен."
    else
        warn "Вердикт: SWAP отсутствует — это может вызвать падение Docker при нехватке памяти."
    fi

    echo ""
    read -rp "$(printf "${YELLOW}Хотите изменить размер или пересоздать SWAP? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Действие отменено."
        press_enter
        return
    fi

    read -rp "$(printf "${CYAN}Введите новый размер SWAP в ГБ [По умолчанию: 1]: ${NC}")" swap_gb
    swap_gb=${swap_gb:-1}
    
    if ! [[ "$swap_gb" =~ ^[0-9]+$ ]]; then
        error "Размер должен быть целым числом!"
        press_enter
        return
    fi

    info "Перенастройка SWAP файла на ${swap_gb}GB..."
    
    measure_time bash -c "
        swapoff /swapfile 2>/dev/null || true
        fallocate -l ${swap_gb}G /swapfile && \
        chmod 600 /swapfile && \
        mkswap /swapfile && \
        swapon /swapfile"
    
    if ! grep -qE '^/swapfile\s' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab >/dev/null
    fi
    
    success "SWAP успешно настроен. Итоговая сводка:"
    free -h
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 4. УПРАВЛЕНИЕ IPv6
# ═══════════════════════════════════════════════════════════════
do_check_ipv6_status() {
    header "Статус IPv6" "IPv6"
    
    local disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    local addresses=$(ip -6 addr show scope global)

    if [ "$disabled" = "1" ]; then
        warn "IPv6 отключен на уровне ядра (disable_ipv6 = 1)."
    else
        success "IPv6 включен на уровне ядра."
    fi

    if [ -n "$addresses" ]; then
        info "Вердикт: IPv6 АДРЕСА ПРИСВОЕНЫ И АКТИВНЫ:"
        echo "$addresses"
    else
        warn "Вердикт: Глобальные IPv6 адреса НЕ НАЙДЕНЫ на интерфейсах."
    fi

    info "Тест соединения (ping6 google.com)..."
    if ping6 -c 1 google.com >/dev/null 2>&1; then
        success "Интернет-соединение через IPv6 работает успешно."
    else
        error "IPv6 не имеет выхода в интернет (ping6 не прошел)."
    fi
    press_enter
}

do_disable_ipv6() {
    header "Отключение IPv6" "IPv6"

    read -rp "$(printf "${YELLOW}Вы уверены, что хотите полностью отключить IPv6? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

    local conf_file="/etc/sysctl.d/99-disable-ipv6.conf"
    
    info "Применение ограничений IPv6..."
    measure_time bash -c "
        printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' > $conf_file
        sysctl -p $conf_file > /dev/null 2>&1
    "
    
    success "IPv6 отключен. Проверяем остаточные адреса..."
    ip -6 addr show scope global
    press_enter
}

do_enable_ipv6() {
    header "Включение IPv6" "IPv6"

    read -rp "$(printf "${YELLOW}Включить IPv6 в системе? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Отменено."
        press_enter
        return
    fi

    local conf_file="/etc/sysctl.d/99-disable-ipv6.conf"
    
    info "Сброс ограничений..."
    measure_time bash -c "
        [ -f '$conf_file' ] && rm '$conf_file'
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 > /dev/null 2>&1
    "
    
    success "IPv6 включен. Возможно, потребуется 'ip link set \$IFACE up' или перезагрузка."
    press_enter
}

menu_ipv6() {
    while true; do
        clear
        header "Управление IPv6" "Система"
        printf "${BLUE}─── Состояние: $(get_ipv6_status) ─────────────────${NC}\n"
        printf "${BOLD}  1)${NC} Проверить статус и пинг\n"
        printf "${BOLD}  2)${NC} Отключить IPv6\n"
        printf "${BOLD}  3)${NC} Включить IPv6\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_check_ipv6_status ;;
            2) do_disable_ipv6 ;;
            3) do_enable_ipv6 ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
# 5. ТЮНИНГ СЕТИ
# ═══════════════════════════════════════════════════════════════
do_network_tuning() {
    header "Продвинутый тюнинг сети" "Система"
    local conf_file="/etc/sysctl.d/99-vpn-tuning.conf"
    
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local wmem=$(sysctl -n net.core.wmem_max 2>/dev/null)
    local fastopen=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)

    info "TCP Read Buffer (max):  ${BOLD}${rmem}${NC}"
    info "TCP Write Buffer (max): ${BOLD}${wmem}${NC}"
    info "TCP FastOpen status:    ${BOLD}${fastopen}${NC}"

    if [ -f "$conf_file" ]; then
        success "Вердикт: Продвинутый тюнинг АКТИВИРОВАН."
    else
        warn "Вердикт: Используются стандартные параметры ядра."
    fi

    echo ""
    if [ -f "$conf_file" ]; then
        read -rp "$(printf "${YELLOW}Вы хотите ОТКЛЮЧИТЬ тюнинг и вернуть стандартные настройки? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            measure_time bash -c "rm -f $conf_file && sysctl --system > /dev/null 2>&1"
            success "Тюнинг успешно отключен."
        fi
    else
        read -rp "$(printf "${CYAN}Вы хотите ВКЛЮЧИТЬ продвинутый тюнинг для VPN? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Применение оптимизаций..."
            measure_time bash -c "
                cat > $conf_file <<EOF
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
EOF
                sysctl --system > /dev/null 2>&1
            "
            success "Сетевые параметры успешно оптимизированы."
        fi
    fi
    press_enter
}

menu_system() {
    while true; do
        clear
        header "Система и Сеть" "Главное меню"
        printf "${BLUE}─── Базовые настройки ───────────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} Обновление системы (APT upgrade)\n"
        printf "${BOLD}  2)${NC} Настройка SWAP\n"
        echo ""
        printf "${BLUE}─── Сетевые настройки ───────────────────────────────${NC}\n"
        printf "${BOLD}  3)${NC} Установка TCP BBR (Ускорение сети)\n"
        printf "${BOLD}  4)${NC} Продвинутый тюнинг сети (VPN)\n"
        printf "${BOLD}  5)${NC} Управление IPv6\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_update ;;
            2) do_setup_swap ;;
            3) do_install_bbr ;;
            4) do_network_tuning ;;
            5) menu_ipv6 ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}
