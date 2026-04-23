#!/usr/bin/env bash
# ============================================================
# Установщик Quick Install (QI)
# Запуск: curl -sSL https://raw.../setup.sh | sudo bash
# ============================================================

set -o pipefail

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
    apt-get update -qq && apt-get install -y git -qq
fi

# Клонируем или обновляем репо
if [ -d "$INSTALL_DIR" ]; then
    info "Обновление файлов в $INSTALL_DIR (принудительно)..."
    cd "$INSTALL_DIR" && git fetch --all >/dev/null 2>&1 && git reset --hard origin/main >/dev/null 2>&1
else
    info "Клонирование репозитория в $INSTALL_DIR..."
    git clone -q "$REPO_URL" "$INSTALL_DIR"
fi

if [ ! -f "${INSTALL_DIR}/src/main.sh" ]; then
    error "Файлы не найдены в ${INSTALL_DIR}/src/. Ошибка скачивания."
    exit 1
fi

chmod +x "${INSTALL_DIR}"/src/*.sh

# Создаем алиас (симлинк не всегда стабилен, сделаем прокси-скрипт)
cat > "$BIN_PATH" <<EOF
#!/bin/bash
if [ "\$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✘]${NC} Утилиту нужно запускать от root (sudo qi)"
    exit 1
fi
exec bash "${INSTALL_DIR}/src/main.sh"
EOF
chmod +x "$BIN_PATH"

success "Установка QI завершена!"
info "Теперь для вызова меню просто пишите в терминале: ${GREEN}${BIN_NAME}${NC}"
echo ""

# Запускаем сразу после установки
exec "$BIN_PATH"
