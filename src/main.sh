#!/usr/bin/env bash

# Главный файл запуска

# Подключение всех модулей
source "$(dirname "${BASH_SOURCE[0]}")/00_globals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/01_helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/02_ufw.sh"
source "$(dirname "${BASH_SOURCE[0]}")/03_node_geo.sh"
source "$(dirname "${BASH_SOURCE[0]}")/04_system.sh"
source "$(dirname "${BASH_SOURCE[0]}")/05_apps.sh"

do_self_update() {
    header "Обновление утилиты QI" "Обновление"
    info "Принудительная синхронизация с GitHub..."
    if cd /opt/quick-install && git fetch --all && git reset --hard origin/main; then
        success "Скрипт успешно синхронизирован с GitHub!"
        read -rp "$(printf "${YELLOW}Перезапустить меню сейчас? [y/N]: ${NC}")" restart_confirm
        if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
            info "Перезапуск..."
            exec qi
        fi
    else
        error "Ошибка при обновлении. Проверьте соединение или права доступа."
    fi
    press_enter
}

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

        show_system_info
        echo ""

        printf "${BLUE}─── Управление ──────────────────────────────────────${NC}\n"
        printf "${BOLD}  1)${NC} ⚙️  Система и Сеть\n"
        printf "${BOLD}  2)${NC} 🐳  Управление Нодой (Proxy)\n"
        echo ""
        printf "${BLUE}─── Защита и Мониторинг ─────────────────────────────${NC}\n"
        printf "${BOLD}  3)${NC} 🛡️  Безопасность\n"
        printf "${BOLD}  4)${NC} 📊  Мониторинг\n"
        echo ""
        printf "${BLUE}─── Дополнительно ───────────────────────────────────${NC}\n"
        printf "${BOLD}  5)${NC} 🧩  Сервисы\n"
        printf "${BOLD}  6)${NC} 🧪  Тесты и Бенчмарки\n"
        echo ""
        printf "${BLUE}─── Утилита ─────────────────────────────────────────${NC}\n"
        printf "${BOLD}  8)${NC} 🔄  Обновить утилиту QI\n"
        echo ""
        printf "${BOLD}  0)${NC} ❌  Выход\n"
        echo ""
        read -rp "$(printf "${CYAN}Выберите действие: ${NC}")" choice

        case "$choice" in
            1) menu_system ;;
            2) menu_node ;;
            3) menu_security ;;
            4) menu_monitoring ;;
            5) menu_apps ;;
            6) menu_tests ;;
            8) do_self_update ;;
            0) echo ""; info "До свидания!"; exit 0 ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

require_root
main_menu
