#!/usr/bin/env bash

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Константы ───────────────────────────────────────────────
REMNA_DIR="/opt/remnanode"
LOG_DIR="/var/log/remnanode"
COMPOSE_FILE="${REMNA_DIR}/docker-compose.yml"
AGH_DIR="/opt/adguardhome"
VPNGUARD_DIR="/opt/vpnguard"
VPNGUARD_CONFIG="${VPNGUARD_DIR}/vpnguard.yaml"
VPNGUARD_COMPOSE_FILE="${VPNGUARD_DIR}/docker-compose.yml"
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Требуются права root. Запустите: sudo bash setup.sh"
        exit 1
    fi
}

