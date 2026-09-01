#!/usr/bin/env bash

do_install_node() {
    header "Установка ноды" "Нода"

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
    ensure_docker || { error "Без Docker установка ноды невозможна."; press_enter; return 1; }
    info "Docker готов: $(docker --version)"

    # 2. Создание папки
    mkdir -p "$REMNA_DIR"
    info "Папка $REMNA_DIR создана."

    # 3. docker-compose.yml
    if [ -f "$COMPOSE_FILE" ]; then
        warn "Файл $COMPOSE_FILE уже существует."
        read -rp "$(printf "${YELLOW}Перезаписать? [y/N]: ${NC}")" overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            info "Пропускаем создание docker-compose.yml."
            press_enter
            return
        fi
    fi

    info "Сейчас откроется nano для редактирования docker-compose.yml"
    info "Вставьте ваш конфиг и сохраните (Ctrl+O, Enter, Ctrl+X)"
    require_commands nano || { press_enter; return 1; }
    sleep 1
    nano "$COMPOSE_FILE"
    chmod 0600 "$COMPOSE_FILE" 2>/dev/null || true

    if [ -f "$COMPOSE_FILE" ] && [ -s "$COMPOSE_FILE" ]; then
        if compose_validate "$REMNA_DIR"; then
            success "docker-compose.yml сохранён и прошёл проверку."
        else
            error "docker-compose.yml содержит ошибку. Исправьте файл перед запуском ноды."
        fi
    else
        warn "docker-compose.yml пуст или не создан."
    fi
    press_enter
}

do_start_node() {
    header "Запуск ноды" "Нода"

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден! Сначала установите ноду."
        press_enter
        return
    fi

    info "Запуск контейнера..."
    if ! measure_time compose_run "$REMNA_DIR" up -d; then
        error "Не удалось запустить контейнер."
        press_enter
        return 1
    fi

    success "Контейнер запущен. Показываю логи (Ctrl+C для выхода)..."
    echo ""
    compose_run "$REMNA_DIR" logs -f -t || true
}

do_update_node() {
    header "Обновление ноды" "Нода"

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден! Обновление невозможно."
        press_enter
        return
    fi

    info "Подтягивание новых образов (docker compose pull)..."
    if ! measure_time compose_run "$REMNA_DIR" pull; then
        error "Не удалось скачать новые образы; работающий контейнер не изменён."
        press_enter
        return 1
    fi
    
    info "Перезапуск контейнера..."
    if ! measure_time compose_run "$REMNA_DIR" up -d --remove-orphans; then
        error "Не удалось применить обновление."
        press_enter
        return 1
    fi
    
    success "Обновление завершено. Показываю логи (Ctrl+C для выхода)..."
    echo ""
    compose_run "$REMNA_DIR" logs -f -t || true
}

do_show_docker_logs() {
    header "Логи контейнера" "Нода"
    if [ ! -d "$REMNA_DIR" ]; then
        error "Папка $REMNA_DIR не найдена."
        press_enter
        return
    fi
    info "Выход: Ctrl+C"
    echo ""
    (trap - INT; compose_run "$REMNA_DIR" logs -f)
}

do_stop_node() {
    header "Остановка ноды" "Нода"
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден!"
        press_enter
        return
    fi
    info "Остановка и удаление контейнеров..."
    compose_run "$REMNA_DIR" down || { error "Не удалось остановить ноду."; press_enter; return 1; }
    success "Нода остановлена."
    press_enter
}

do_restart_node() {
    header "Перезапуск ноды" "Нода"
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден!"
        press_enter
        return
    fi
    info "Перезапуск (down + up)..."
    compose_run "$REMNA_DIR" restart || { error "Не удалось перезапустить ноду."; press_enter; return 1; }
    success "Нода перезапущена."
    press_enter
}

do_edit_node_compose() {
    header "Редактирование docker-compose.yml" "Нода"
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Файл $COMPOSE_FILE не найден!"
        press_enter
        return
    fi
    info "Открываю nano для редактирования $COMPOSE_FILE..."
    require_commands nano || { press_enter; return 1; }
    cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
    chmod 0600 "${COMPOSE_FILE}.bak" 2>/dev/null || true
    sleep 1
    nano "$COMPOSE_FILE"
    chmod 0600 "$COMPOSE_FILE" 2>/dev/null || true
    if compose_validate "$REMNA_DIR"; then
        success "Редактирование завершено; Compose-конфигурация корректна."
    else
        cp -p "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
        error "Compose-конфигурация некорректна; восстановлена резервная копия."
    fi
    press_enter
}

do_download_geo() {
    header "Загрузка/Обновление Geo файлов" "Нода > Geo"

    # 1. Запросить ссылку
    read -rp "$(printf "${CYAN}Введите ссылку на geo файл: ${NC}")" geo_url
    if [ -z "$geo_url" ]; then error "Отменено."; return; fi
    if [[ ! "$geo_url" =~ ^https:// ]]; then error "Разрешены только HTTPS-ссылки."; press_enter; return 1; fi

    # 2. Скачать и добавить в папку
    local geo_dir="${REMNA_DIR}/geo"
    mkdir -p "$geo_dir"
    
    # Получаем имя файла из ссылки
    local filename
    filename=$(basename "${geo_url%%\?*}")
    if [ -z "$filename" ] || ! [[ "$filename" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$filename" = "." ] || [ "$filename" = ".." ]; then
        error "Небезопасное или пустое имя файла в URL."
        press_enter
        return 1
    fi

    info "Скачивание $filename в $geo_dir..."
    if ! download_atomic "$geo_url" "${geo_dir}/${filename}"; then
        error "Ошибка при скачивании файла!"
        press_enter
        return
    fi
    success "Файл $filename успешно скачан."

    # Сохраняем ссылку в urls.txt
    local urls_file="${geo_dir}/urls.txt"
    touch "$urls_file"
    awk -F'|' -v name="$filename" '$1 != name' "$urls_file" > "${urls_file}.tmp" 2>/dev/null || true
    echo "${filename}|${geo_url}" >> "${urls_file}.tmp"
    mv "${urls_file}.tmp" "$urls_file"
    info "Ссылка на файл сохранена."

    # 3. Прописать в docker-compose.yml
    if [ -f "$COMPOSE_FILE" ]; then
        if grep -Fq "${geo_dir}/${filename}" "$COMPOSE_FILE"; then
            info "Volume для $filename уже прописан."
            read -rp "$(printf "${YELLOW}Перезапустить контейнер для применения обновлённого файла? [y/N]: ${NC}")" restart_confirm
            if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
                if compose_run "$REMNA_DIR" up -d; then success "Контейнер перезапущен."; else error "Ошибка перезапуска."; fi
            fi
        else
            read -rp "$(printf "${CYAN}Путь внутри контейнера [По умолчанию: /usr/local/share/xray]: ${NC}")" container_path
            container_path=${container_path:-/usr/local/share/xray}
            container_path="${container_path%/}"

            local volume_mapping="${geo_dir}/${filename}:${container_path}/${filename}:ro"
            info "Добавляю $filename в volumes..."
            cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
            chmod 0600 "${COMPOSE_FILE}.bak" 2>/dev/null || true

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
            chmod 0600 "$COMPOSE_FILE" 2>/dev/null || true

            if grep -Fq "${geo_dir}/${filename}" "$COMPOSE_FILE" && compose_validate "$REMNA_DIR"; then
                success "docker-compose.yml обновлен."
                read -rp "$(printf "${YELLOW}Перезапустить контейнер для применения изменений? [y/N]: ${NC}")" restart_confirm
                if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
                    if compose_run "$REMNA_DIR" up -d; then success "Контейнер перезапущен."; else error "Ошибка перезапуска."; fi
                fi
            else
                cp -p "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
                error "Не удалось безопасно обновить Compose; восстановлена резервная копия."
            fi
        fi
    fi
    press_enter
}

do_update_all_geo() {
    header "Обновление всех Geo файлов" "Нода > Geo"
    local geo_dir="${REMNA_DIR}/geo"
    local urls_file="${geo_dir}/urls.txt"

    if [ ! -f "$urls_file" ] || [ ! -s "$urls_file" ]; then
        error "Список ссылок пуст!"
        press_enter
        return
    fi

    local total
    total=$(wc -l < "$urls_file")
    info "Найдено файлов для обновления: $total"
    
    local count=0
    while IFS='|' read -r filename url || [ -n "$filename" ]; do
        [ -z "$filename" ] || [ -z "$url" ] && continue
        info "[$((count+1))/$total] Скачивание $filename..."
        if [[ "$url" =~ ^https:// ]] && [[ "$filename" =~ ^[A-Za-z0-9._-]+$ ]] && download_atomic "$url" "${geo_dir}/${filename}"; then
            success "$filename обновлен."
            count=$((count + 1))
        else
            error "$filename не обновлён; предыдущий файл сохранён."
        fi
    done < "$urls_file"

    if [ "$count" -gt 0 ]; then
        success "Обновлено файлов: $count"
        read -rp "$(printf "${YELLOW}Перезапустить контейнер для применения изменений? [y/N]: ${NC}")" restart_confirm
        if [[ "$restart_confirm" =~ ^[Yy]$ ]]; then
            if compose_run "$REMNA_DIR" restart; then success "Контейнер перезапущен."; else error "Ошибка перезапуска."; fi
        fi
    fi
    press_enter
}

manage_geo_autoupdate() {
    header "Автообновление Geo" "Нода > Geo"
    local cron_script="${REMNA_DIR}/scripts/update_geo.sh"
    local cron_job="0 3 * * 1 bash $cron_script > /dev/null 2>&1"

    local is_enabled=false
    crontab -l 2>/dev/null | grep -q "$cron_script" && is_enabled=true

    if [ "$is_enabled" = true ]; then
        success "Автообновление ВКЛЮЧЕНО (Пн, 03:00)."
        read -rp "$(printf "${YELLOW}Вы хотите ОТКЛЮЧИТЬ его? [y/N]: ${NC}")" disable_confirm
        if [[ "$disable_confirm" =~ ^[Yy]$ ]]; then
            crontab -l 2>/dev/null | grep -v "$cron_script" | crontab -
            success "Автообновление отключено."
        fi
    else
        warn "Автообновление ВЫКЛЮЧЕНО."
        read -rp "$(printf "${CYAN}Вы хотите ВКЛЮЧИТЬ автообновление (раз в неделю)? [y/N]: ${NC}")" enable_confirm
        if [[ "$enable_confirm" =~ ^[Yy]$ ]]; then
            mkdir -p "${REMNA_DIR}/scripts"
            cat > "$cron_script" <<EOF
#!/bin/bash
GEO_DIR="${REMNA_DIR}/geo"
URLS_FILE="\${GEO_DIR}/urls.txt"
if [ -f "\$URLS_FILE" ]; then
    changed=0
    while IFS='|' read -r filename url; do
        case "\$filename" in *[!A-Za-z0-9._-]*|.|..) continue ;; esac
        case "\$url" in https://*) ;; *) continue ;; esac
        tmp=\$(mktemp "\${GEO_DIR}/\${filename}.tmp.XXXXXX") || continue
        if curl -fL --connect-timeout 10 --retry 2 "\$url" -o "\$tmp" && [ -s "\$tmp" ]; then
            mv -f "\$tmp" "\${GEO_DIR}/\${filename}"
            changed=1
        else
            rm -f "\$tmp"
        fi
    done < "\$URLS_FILE"
    [ "\$changed" -eq 1 ] && cd "${REMNA_DIR}" && docker compose restart
fi
EOF
            chmod +x "$cron_script"
            (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
            success "Автообновление включено."
        fi
    fi
    press_enter
}

do_show_access_logs() {
    header "Логи подключений" "Нода"
    local log_file="/var/log/remnanode/access.log"
    if [ ! -f "$log_file" ]; then
        error "Файл $log_file не найден."
        press_enter
        return
    fi
    info "Выход: Ctrl+C"
    echo ""
    # Родитель игнорирует INT (не вылетит), подшелл сбрасывает (tail получит Ctrl+C)
    trap '' INT
    (trap - INT; tail -f "$log_file")
    trap - INT
}

menu_geo() {
    while true; do
        clear
        header "Управление Geo файлами" "Нода"
        menu_section "GeoIP / GeoSite"
        menu_item 1 "Добавить Geo-файл"
        menu_item 2 "Обновить все Geo-файлы"
        menu_item 3 "Настроить автообновление"
        menu_back
        read_choice choice

        case "$choice" in
            1) do_download_geo ;;
            2) do_update_all_geo ;;
            3) manage_geo_autoupdate ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}

menu_node() {
    while true; do
        clear
        header "Управление Нодой" "Главное меню"
        
        menu_section "Состояние: $(get_docker_status "remnanode")"
        menu_item 1 "Запустить и показать логи"
        menu_item 2 "Перезапустить"
        menu_item 3 "Остановить"
        menu_item 4 "Показать логи контейнера"
        menu_item 5 "Показать access.log"
        echo ""
        menu_section "Установка и конфигурация"
        menu_item 6 "Установить ноду"
        menu_item 7 "Обновить образы ноды"
        menu_item 8 "Редактировать docker-compose.yml"
        menu_item 9 "Управлять Geo-файлами"
        menu_back
        read_choice choice

        case "$choice" in
            1) do_start_node ;;
            2) do_restart_node ;;
            3) do_stop_node ;;
            4) do_show_docker_logs ;;
            5) do_show_access_logs ;;
            6) do_install_node ;;
            7) do_update_node ;;
            8) do_edit_node_compose ;;
            9) menu_geo ;;
            0) return ;;
            *) warn "Неверный выбор." ; sleep 1 ;;
        esac
    done
}
