#!/usr/bin/env bash
# ============================================================
# Установщик Quick Install (QI)
# Запуск: curl -sSL https://raw.../setup.sh | sudo bash
# ============================================================

set -Eeuo pipefail

# ─── Цвета ─────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "${CYAN}[INFO]${NC} %b\n" "$*"; }
success() { printf "${GREEN}[✔]${NC} %b\n" "$*"; }
error()   { printf "${RED}[✘]${NC} %b\n" "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    error "Требуются права root. Запустите через sudo."
    exit 1
fi

INSTALL_DIR="/opt/quick-install"
BIN_NAME="qi"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
REPO_URL="https://github.com/onelove999/Quick-Install.git"

info "Скачивание файлов утилиты..."

# Устанавливаем git если нет
if ! command -v git &>/dev/null; then
    info "Установка Git..."
    if ! command -v apt-get &>/dev/null; then
        error "Автоматическая установка поддерживает Debian/Ubuntu (apt-get)."
        exit 1
    fi
    apt-get update -qq
    apt-get install -y -qq git ca-certificates
fi

# Клонируем или обновляем репо
if [ -e "$INSTALL_DIR" ]; then
    if [ ! -d "$INSTALL_DIR/.git" ]; then
        error "$INSTALL_DIR уже существует, но не является Git-репозиторием."
        error "Удалите или переместите каталог вручную и повторите установку."
        exit 1
    fi
    current_remote=$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)
    if [ "$current_remote" != "$REPO_URL" ]; then
        error "Неожиданный origin у $INSTALL_DIR: ${current_remote:-не задан}"
        exit 1
    fi
    if [ -n "$(git -C "$INSTALL_DIR" status --porcelain)" ]; then
        error "В $INSTALL_DIR есть локальные изменения; автоматическое обновление их не удаляет."
        error "Сохраните изменения или восстановите чистое состояние репозитория вручную."
        exit 1
    fi
    info "Обновление файлов в $INSTALL_DIR (принудительно)..."
    git -C "$INSTALL_DIR" fetch --prune origin main
    git -C "$INSTALL_DIR" reset --hard origin/main
else
    info "Клонирование репозитория в $INSTALL_DIR..."
    git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR"
fi

if [ ! -f "${INSTALL_DIR}/src/main.sh" ]; then
    error "Файлы не найдены в ${INSTALL_DIR}/src/. Ошибка скачивания."
    exit 1
fi

chmod 0755 "${INSTALL_DIR}"/src/*.sh

# Создаем алиас (симлинк не всегда стабилен, сделаем прокси-скрипт)
launcher_tmp=$(mktemp "${BIN_PATH}.tmp.XXXXXX")
cat > "$launcher_tmp" <<EOF
#!/bin/bash
if [ "\$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✘]${NC} Утилиту нужно запускать от root (sudo qi)"
    exit 1
fi
exec bash "${INSTALL_DIR}/src/main.sh" "\$@"
EOF
chmod 0755 "$launcher_tmp"
mv -f "$launcher_tmp" "$BIN_PATH"

success "Установка QI завершена!"
info "Теперь для вызова меню просто пишите в терминале: ${GREEN}${BIN_NAME}${NC}"
echo ""

# При установке через curl | bash stdin уже закрыт — меню запускать нельзя.
if [ -t 0 ] && [ -t 1 ]; then
    exec "$BIN_PATH"
fi
info "Для запуска интерактивного меню выполните: ${GREEN}sudo ${BIN_NAME}${NC}"
