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
# 2. УСТАНОВКА TCP BBR И ПРОДВИНУТЫЙ ТЮНИНГ СЕТИ
# ═══════════════════════════════════════════════════════════════
do_network_tuning() {
    header "TCP BBR и Тюнинг сети" "Система"

    local bbr_conf="/etc/sysctl.d/99-bbr.conf"
    local tuning_conf="/etc/sysctl.d/99-vpn-tuning.conf"
    
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local kernel_ver=$(uname -r)

    info "Текущее ядро: ${BOLD}${kernel_ver}${NC}"
    info "Алгоритм (CC):  ${BOLD}${cur_cc}${NC} | Очередь (Qdisc): ${BOLD}${cur_qdisc}${NC}"

    if [ "$cur_cc" = "bbr" ] && [ -f "$tuning_conf" ]; then
        success "Вердикт: BBR и продвинутый тюнинг АКТИВНЫ."
    elif [ "$cur_cc" = "bbr" ]; then
        warn "Вердикт: Активен только BBR (без полного тюнинга)."
    else
        warn "Вердикт: Используются стандартные параметры ядра."
    fi

    echo ""
    printf "Доступные действия:\n"
    if [ "$cur_cc" = "bbr" ] || [ -f "$tuning_conf" ]; then
        printf "${BOLD}  1)${NC} Обновить / Переустановить BBR + Тюнинг\n"
        printf "${BOLD}  2)${NC} ${RED}Отключить BBR и Тюнинг${NC} (вернуть стандарт)\n"
    else
        printf "${BOLD}  1)${NC} Включить TCP BBR и Продвинутый тюнинг (Рекомендуется)\n"
    fi
    printf "${BOLD}  0)${NC} ← Назад\n"
    echo ""
    read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" tune_choice

    case "$tune_choice" in
        1)
            info "Создание резервной копии текущих настроек..."
            mkdir -p /var/backups/quick-install 2>/dev/null
            sysctl -a > /var/backups/quick-install/sysctl-backup-$(date +%Y%m%d-%H%M%S).txt 2>/dev/null

            info "Настройка BBR и применение оптимизаций..."
            measure_time bash -c "
                modprobe tcp_bbr 2>/dev/null || true
                mkdir -p /etc/sysctl.d
                
                # Конфиг BBR
                echo 'net.core.default_qdisc = fq' > $bbr_conf
                echo 'net.ipv4.tcp_congestion_control = bbr' >> $bbr_conf
                
                # Конфиг тюнинга
                cat > $tuning_conf <<EOF
# Базовые параметры маршрутизации
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

# Оптимизация TCP для уменьшения задержек (из node-diagnostic)
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.tcp_fastopen=3

# Увеличение буферов TCP для высокоскоростных соединений
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# Очереди и соединения (скорректировано из node-diagnostic)
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192

# Увеличение conntrack для большого количества клиентов
net.netfilter.nf_conntrack_max=524288
EOF
                sysctl --system > /dev/null 2>&1
            "
            success "TCP BBR и сетевые оптимизации успешно применены."
            ;;
        2)
            if [ "$cur_cc" = "bbr" ] || [ -f "$tuning_conf" ]; then
                info "Отключение BBR и сетевого тюнинга..."
                measure_time bash -c "
                    rm -f $bbr_conf $tuning_conf
                    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
                    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
                    sysctl --system >/dev/null 2>&1
                "
                success "Система возвращена к стандартным настройкам сети."
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
# 5. НАСТРОЙКА MSS CLAMP (ДЛЯ ТУННЕЛЕЙ С PMTU < 1500)
# ═══════════════════════════════════════════════════════════════
do_mss_clamp() {
    header "Настройка MSS Clamp" "Система"
    
    info "Правило TCPMSS --clamp-mss-to-pmtu помогает избежать проблем с"
    info "фрагментацией (например, долго грузятся картинки) при использовании"
    info "туннелей (WireGuard, GRE, IPsec, NetBird и др.) с MTU < 1500."
    echo ""
    
    local rule_args="-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    
    # Проверка наличия правил
    local has_forward=0
    local has_output=0
    
    if iptables -t mangle -C FORWARD $rule_args 2>/dev/null; then has_forward=1; fi
    if iptables -t mangle -C OUTPUT $rule_args 2>/dev/null; then has_output=1; fi
    
    if [ "$has_forward" = "1" ] && [ "$has_output" = "1" ]; then
        success "Вердикт: Правила MSS Clamp уже ПРИМЕНЕНЫ."
        echo ""
        read -rp "$(printf "${YELLOW}Вы хотите УДАЛИТЬ правила MSS Clamp? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            measure_time bash -c "
                iptables -t mangle -D FORWARD $rule_args 2>/dev/null || true
                iptables -t mangle -D OUTPUT $rule_args 2>/dev/null || true
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1
                fi
            "
            success "Правила MSS Clamp успешно удалены."
        fi
    else
        warn "Вердикт: Правила MSS Clamp НЕ активны."
        echo ""
        read -rp "$(printf "${CYAN}Вы хотите ДОБАВИТЬ правила MSS Clamp? [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Применение правил iptables..."
            measure_time bash -c "
                [ \"$has_forward\" = \"0\" ] && iptables -t mangle -A FORWARD $rule_args
                [ \"$has_output\" = \"0\" ] && iptables -t mangle -A OUTPUT $rule_args
                
                # Попытка сохранить правила, если установлены пакеты
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1
                elif [ -d /etc/iptables ] && command -v iptables-save >/dev/null 2>&1; then
                    iptables-save > /etc/iptables/rules.v4
                fi
            "
            success "Правила MSS Clamp успешно применены."
            if ! command -v netfilter-persistent >/dev/null 2>&1; then
                warn "Пакет iptables-persistent не найден. Правила могут пропасть после перезагрузки."
                echo ""
                read -rp "$(printf "${CYAN}Хотите установить iptables-persistent для сохранения правил? [Y/n]: ${NC}")" install_persistent
                if [[ ! "$install_persistent" =~ ^[Nn]$ ]]; then
                    info "Установка iptables-persistent..."
                    if command -v debconf-set-selections >/dev/null 2>&1; then
                        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
                        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
                    fi
                    export DEBIAN_FRONTEND=noninteractive
                    apt-get update -qq && apt-get install -y -qq iptables-persistent netfilter-persistent
                    if command -v netfilter-persistent >/dev/null 2>&1; then
                        netfilter-persistent save >/dev/null 2>&1
                        success "Пакет успешно установлен, правила MSS Clamp сохранены."
                    else
                        error "Не удалось установить iptables-persistent."
                    fi
                fi
            fi
        fi
    fi
    press_enter
}

# ═══════════════════════════════════════════════════════════════
# 6. АППАРАТНЫЙ ТЮНИНГ (RPS и Ring Buffers)
# ═══════════════════════════════════════════════════════════════
do_hardware_tuning() {
    header "Аппаратный тюнинг NIC" "Система"
    
    local iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$iface" ]; then
        error "Не удалось определить основной сетевой интерфейс."
        press_enter
        return
    fi
    info "Основной интерфейс: ${BOLD}${iface}${NC}"
    echo ""
    
    info "Выполняется диагностика..."
    
    local needs_rps=0
    local needs_ring=0
    local rps_msg=""
    local ring_msg=""
    
    # 1. Проверка прерываний (RPS)
    local rps_active=0
    for q in /sys/class/net/"$iface"/queues/rx-*; do
        [ -d "$q" ] || continue
        local val=$(cat "$q/rps_cpus" 2>/dev/null)
        if [ "$val" != "0" ] && [ -n "$val" ]; then
            rps_active=1
            break
        fi
    done
    
    if [ "$rps_active" = "1" ] || systemctl is-enabled vpn-rps.service >/dev/null 2>&1; then
        success "RPS (Receive Packet Steering): АКТИВЕН"
    else
        needs_rps=1
        warn "RPS (Receive Packet Steering): ВЫКЛЮЧЕН"
        rps_msg="Рекомендуется включить RPS для распределения сетевых прерываний по всем ядрам CPU."
    fi

    # 2. Проверка Ring Buffers
    local max_rx="" cur_rx="" max_tx="" cur_tx="" rx_drops="0" tx_drops="0"
    rx_drops=$(ip -s link show "$iface" | awk '/RX:/{getline; print $4}')
    tx_drops=$(ip -s link show "$iface" | awk '/TX:/{getline; print $4}')
    
    if command -v ethtool >/dev/null 2>&1; then
        max_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set maximums/,/Current/' | awk '/RX:/ {print $2; exit}')
        cur_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/Current hardware settings/,0' | awk '/RX:/ {print $2; exit}')
        max_tx=$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set maximums/,/Current/' | awk '/TX:/ {print $2; exit}')
        
        if [ -z "$max_rx" ] || [ "$max_rx" = "0" ]; then
            warn "Ring Buffers: Не поддерживается драйвером (часто на виртуалках virtio_net)."
        elif [ "$cur_rx" = "$max_rx" ] || systemctl is-enabled vpn-ring.service >/dev/null 2>&1; then
            success "Ring Buffers: НА МАКСИМУМЕ ($cur_rx/$max_rx) | Дропы: RX=${rx_drops:-0}, TX=${tx_drops:-0}"
        else
            needs_ring=1
            warn "Ring Buffers: Текущие ($cur_rx), Максимальные ($max_rx) | Дропы: RX=${rx_drops:-0}, TX=${tx_drops:-0}"
            ring_msg="Рекомендуется увеличить Ring Buffers до максимума для снижения потерь пакетов."
        fi
    else
        warn "Ring Buffers: утилита ethtool не установлена. Для проверки выполните: apt install ethtool"
    fi

    echo ""
    if [ "$needs_rps" = "0" ] && [ "$needs_ring" = "0" ]; then
        success "Аппаратные оптимизации не требуются или уже применены."
        if systemctl is-enabled vpn-rps.service >/dev/null 2>&1 || systemctl is-enabled vpn-ring.service >/dev/null 2>&1; then
            echo ""
            read -rp "$(printf "${YELLOW}Отключить аппаратные оптимизации и удалить сервисы? [y/N]: ${NC}")" confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl disable --now vpn-rps.service 2>/dev/null || true
                systemctl disable --now vpn-ring.service 2>/dev/null || true
                rm -f /etc/systemd/system/vpn-rps.service /etc/systemd/system/vpn-ring.service
                systemctl daemon-reload
                for q in /sys/class/net/$iface/queues/rx-*; do [ -d "$q" ] && echo 0 > "$q/rps_cpus" 2>/dev/null || true; done
                success "Аппаратные оптимизации успешно отключены."
            fi
        fi
        press_enter
        return
    fi
    
    [ "$needs_rps" = "1" ] && info "-> $rps_msg"
    [ "$needs_ring" = "1" ] && info "-> $ring_msg"
    
    echo ""
    read -rp "$(printf "${CYAN}Установить предложенные аппаратные оптимизации (создадутся systemd сервисы)? [y/N]: ${NC}")" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        info "Применение оптимизаций..."
        
        if [ "$needs_rps" = "1" ]; then
            local n=$(nproc)
            local mask=$(printf '%x' $(( (1 << n) - 1 )))
            
            cat > /etc/systemd/system/vpn-rps.service <<UNIT
[Unit]
Description=Apply RPS mask for $iface
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for q in /sys/class/net/$iface/queues/rx-*; do echo $mask > \$\$q/rps_cpus; done'

[Install]
WantedBy=multi-user.target
UNIT
            systemctl daemon-reload
            systemctl enable --now vpn-rps.service >/dev/null 2>&1
            success "Служба vpn-rps.service (RPS) установлена и запущена."
        fi
        
        if [ "$needs_ring" = "1" ]; then
            cat > /etc/systemd/system/vpn-ring.service <<UNIT
[Unit]
Description=Apply NIC ring buffers for $iface
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ethtool -G $iface rx $max_rx tx $max_tx

[Install]
WantedBy=multi-user.target
UNIT
            systemctl daemon-reload
            systemctl enable --now vpn-ring.service >/dev/null 2>&1
            success "Служба vpn-ring.service (Ring Buffers) установлена и запущена."
        fi
    else
        info "Действие отменено."
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
        printf "${BOLD}  3)${NC} Установка TCP BBR и Тюнинг сети\n"
        printf "${BOLD}  4)${NC} Управление IPv6\n"
        printf "${BOLD}  5)${NC} Настройка MSS Clamp (для туннелей)\n"
        printf "${BOLD}  6)${NC} Аппаратный тюнинг (RPS и Ring Buffers)\n"
        echo ""
        printf "${BOLD}  0)${NC} ← Назад\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) do_update ;;
            2) do_setup_swap ;;
            3) do_network_tuning ;;
            4) menu_ipv6 ;;
            5) do_mss_clamp ;;
            6) do_hardware_tuning ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}
