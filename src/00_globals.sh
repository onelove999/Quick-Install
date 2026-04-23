#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# ЦВЕТА И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# ═══════════════════════════════════════════════════════════════

# Цвета терминала
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Пути
REMNA_DIR="/opt/remnanode"
COMPOSE_FILE="${REMNA_DIR}/docker-compose.yml"
AGH_DIR="/opt/adguardhome"
LOG_DIR="/var/log/remnanode"

# Конфиг VPN Guard
VPNGUARD_DIR="/opt/vpnguard"
VPNGUARD_CONFIG="${VPNGUARD_DIR}/config/config.yaml"
