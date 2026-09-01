#!/usr/bin/env bash

# Главный файл запуска

set -o pipefail

# Подключение всех модулей
source "$(dirname "${BASH_SOURCE[0]}")/00_globals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/01_helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/02_ufw.sh"
source "$(dirname "${BASH_SOURCE[0]}")/03_node_geo.sh"
source "$(dirname "${BASH_SOURCE[0]}")/04_system.sh"
source "$(dirname "${BASH_SOURCE[0]}")/05_apps.sh"
source "$(dirname "${BASH_SOURCE[0]}")/06_diagnostics.sh"

do_self_update() {
    header "Обновление утилиты QI" "Обновление"
    local install_dir="/opt/quick-install" expected_remote="https://github.com/onelove999/Quick-Install.git"
    if [ ! -d "$install_dir/.git" ]; then
        error "$install_dir не является Git-репозиторием. Переустановите QI через setup.sh."
        press_enter
        return 1
    fi
    if [ "$(git -C "$install_dir" remote get-url origin 2>/dev/null)" != "$expected_remote" ]; then
        error "Обновление остановлено: origin репозитория не совпадает с ожидаемым."
        press_enter
        return 1
    fi
    if [ -n "$(git -C "$install_dir" status --porcelain)" ]; then
        warn "В каталоге QI есть локальные изменения. Обновление удалит их."
        if ! confirm_action "Продолжить и сбросить локальные изменения"; then
            info "Обновление отменено."
            press_enter
            return 1
        fi
    fi
    info "Принудительная синхронизация с GitHub..."
    if git -C "$install_dir" fetch --prune origin main && git -C "$install_dir" reset --hard origin/main; then
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

        menu_section "Управление"
        menu_item 1 "Система и сеть"
        menu_item 2 "Управление нодой"
        echo ""
        menu_section "Защита и мониторинг"
        menu_item 3 "Безопасность"
        menu_item 4 "Мониторинг"
        echo ""
        menu_section "Дополнительно"
        menu_item 5 "Сервисы"
        menu_item 6 "Тесты и диагностика"
        echo ""
        menu_section "Утилита"
        menu_item 7 "Обновить QI"
        echo ""
        menu_item 0 "Выход"
        echo ""
        read_choice choice

        case "$choice" in
            1) menu_system ;;
            2) menu_node ;;
            3) menu_security ;;
            4) menu_monitoring ;;
            5) menu_apps ;;
            6) menu_tests ;;
            7) do_self_update ;;
            0) echo ""; info "До свидания!"; exit 0 ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

require_root
main_menu
