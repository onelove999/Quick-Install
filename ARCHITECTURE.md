# Quick-Install (QI) — Архитектура проекта

> **Этот файл — главный справочник по ВСЕМУ проекту.** Любая нейросеть, прочитав его, должна полностью понять структуру, логику и зависимости. **При внесении структурных изменений — обновляй этот файл.**

## Что это

**Quick-Install (QI)** — интерактивная утилита для развёртывания и управления VPN-серверами на базе Xray/Remnawave. Устанавливается одной командой `curl | bash`, создаёт алиас `qi` в системе, предоставляет TUI-меню для управления нодой, безопасностью, мониторингом и сервисами.

**Репозиторий**: `github.com/onelove999/Quick-Install`  
**Установка**: `curl -sSL https://raw.../setup.sh | sudo bash`  
**Запуск**: `qi` (алиас, требует root)

## Структура репозитория

```
Quick-Install/
├── setup.sh                 # Установщик: клонирует репо в /opt/quick-install, создаёт алиас qi
├── .gitignore               # Исключения: Ansible, секреты, runtime и локальные артефакты
├── ARCHITECTURE.md          # ← ЭТОТ ФАЙЛ
├── AGENTS.md                # Универсальные правила для coding-агентов
├── gemini.md                # Дополнительные инструкции для Gemini
│
├── src/                     # Bash-модули скрипта
│   ├── main.sh              # Точка входа: source модулей + главное меню
│   ├── 00_globals.sh        # Цвета, глобальные переменные, пути
│   ├── 01_helpers.sh        # Утилиты: info/warn/error, header, measure_time, show_system_info
│   ├── 02_ufw.sh            # Управление файрволом UFW
│   ├── 03_node_geo.sh       # Установка/управление нодой Remnawave + GeoIP/GeoSite
│   ├── 04_system.sh         # Система: обновления, BBR, SWAP, IPv6, тюнинг сети
│   ├── 05_apps.sh           # Приложения: VPN Guard, Beszel, WARP, AdGuard, тесты
│   └── 06_diagnostics.sh    # Комплексная диагностика сети и железа ноды
│
├── ansible/                 # Декларативное развёртывание VPN-нод
│   ├── deploy.yml           # Главный playbook
│   ├── inventory.ini        # Пример inventory
│   ├── group_vars/          # Общие настройки всех нод
│   ├── host_vars/           # Индивидуальные параметры нод
│   ├── collections/         # Зависимости Ansible Galaxy
│   └── roles/               # base_os, firewall, docker, vpn_core и опциональные сервисы
│
└── vpnguard/                # Go-модуль VPN Guard (собирается в Docker)
    ├── main.go              # CLI: --config, --interactive, --report, --list-models
    ├── Dockerfile           # Alpine multi-stage build
    ├── vpnguard.yaml.example
    ├── config/
    │   └── config.go        # Загрузка YAML, структуры, дефолты, валидация
    ├── daemon/
    │   ├── daemon.go        # Tail лог-файла, fsnotify, обработка строк
    │   ├── parser.go        # ParseLine() — парсинг Xray access.log
    │   ├── scorer.go        # Движок баллов, flood detection, breakdown
    │   ├── parser_test.go
    │   └── scorer_test.go
    ├── alerter/
    │   ├── telegram.go      # Отправка алертов в Telegram (текст + файл)
    │   ├── qwen.go          # AI-клиент Qwen (OpenAI-совместимый)
    │   ├── gemini.go        # AI-клиент Google Gemini
    │   └── ai_chain.go      # Оркестратор: Qwen → retry → Gemini fallback
    └── cli/
        ├── interactive.go   # Интерактивная фильтрация логов
        └── report.go        # Сводный отчёт с анализом активности
```

---

## Часть 1: Bash-скрипт (src/)

### Как загружается

```
setup.sh → клонирует репо в /opt/quick-install → создаёт /usr/local/bin/qi
qi → exec bash /opt/quick-install/src/main.sh
main.sh → source 00..06 → main_menu()
```

### Модули и их функции

#### 00_globals.sh — Переменные

| Переменная | Значение |
|---|---|
| `REMNA_DIR` | `/opt/remnanode` |
| `COMPOSE_FILE` | `/opt/remnanode/docker-compose.yml` |
| `AGH_DIR` | `/opt/adguardhome` |
| `LOG_DIR` | `/var/log/remnanode` |
| `VPNGUARD_DIR` | `/opt/vpnguard` |
| `VPNGUARD_CONFIG` | `/opt/vpnguard/config/config.yaml` |

#### 01_helpers.sh — Утилиты

| Функция | Описание |
|---|---|
| `info()`, `success()`, `warn()`, `error()` | Цветной вывод |
| `menu_section()`, `menu_item()`, `menu_back()` | Единое оформление меню |
| `read_choice()`, `confirm_action()` | Единый ввод и подтверждения |
| `header(title, parent)` | Заголовок секции |
| `get_docker_status(name)` | Статус контейнера: Запущен/Остановлен/Не установлен |
| `get_bbr_status()`, `get_ipv6_status()`, `get_ufw_status()` | Статусные индикаторы |
| `is_valid_ip()`, `is_valid_port()`, `is_valid_port_spec()`, `is_valid_protocol()` | Валидация сетевого ввода |
| `measure_time(cmd)` | Замер времени выполнения |
| `download_atomic()`, `run_remote_script()` | Безопасная загрузка и запуск внешних скриптов |
| `compose_run()`, `compose_validate()`, `ensure_docker()` | Общая работа с Docker Compose |
| `show_system_info()` | Блок информации о сервере (OS, IP, RAM, Load, BBR, IPv6) |
| `press_enter()` | Пауза "Нажмите Enter" |
| `require_root()` | Проверка root |

#### 02_ufw.sh — Файрвол

| Функция | Описание |
|---|---|
| `menu_ufw()` | Меню управления UFW |
| Управление правилами | Добавление/удаление портов, whitelisting IP |

#### 03_node_geo.sh — Нода Remnawave

| Функция | Описание |
|---|---|
| `do_install_node()` | Установка ноды Remnawave |
| `do_start_node()` | Запуск docker compose |
| `do_update_node()` | Обновление образа |
| `menu_node()` | Основное меню ноды |
| GeoIP/GeoSite | Обновление гео-баз, управление правилами маршрутизации Xray |

#### 04_system.sh — Система

| Функция | Описание |
|---|---|
| `do_update()` | APT upgrade |
| `do_setup_swap()` | Настройка SWAP файла |
| `do_network_tuning()` | Установка TCP BBR и продвинутый тюнинг сети |
| `menu_ipv6()` | Включение/отключение/проверка IPv6 |
| `do_mss_clamp()` | Настройка MSS Clamp (для туннелей) |
| `do_hardware_tuning()` | Аппаратный тюнинг (RPS и Ring Buffers) |
| `menu_system()` | Общее меню системы |

#### 05_apps.sh — Приложения и сервисы

**VPN Guard** (строки ~1–520):
| Функция | Описание |
|---|---|
| `compose_vpnguard()` | Обёртка для docker compose в VPNGUARD_DIR |
| `vpnguard_get_value(key)` | Чтение значения из YAML конфига |
| `vpnguard_update_config_value(key, value)` | Запись значения в YAML через sed |
| `download_vpnguard_source()` | Скачивание исходников Go из GitHub |
| `generate_vpnguard_config()` | Интерактивная генерация YAML (Telegram, Qwen, Gemini) |
| `generate_vpnguard_compose()` | Генерация docker-compose.yml |
| `do_install_vpnguard()` | Полная установка: скачать → конфиг → build → up |
| `do_vpnguard_settings()` | Меню настроек (1-6 основные, 7-9 AI) |
| `menu_vpnguard()` | Главное меню VPN Guard |

**Beszel Agent** (строки ~525–590):
| Функция | Описание |
|---|---|
| `do_install_beszel()` | Установка Beszel мониторинг-агента |

**Cloudflare WARP** (строки ~590–730):
| Функция | Описание |
|---|---|
| `do_install_warp()` | Установка WireGuard WARP (для обхода блокировок) |
| `do_uninstall_warp()` | Полное удаление WARP |
| `menu_warp()` | Меню WARP |

**AdGuard Home** (строки ~730–880):
| Функция | Описание |
|---|---|
| `do_install_adguard()` | Установка AdGuard Home (DNS-фильтрация) |
| `menu_adguard()` | Меню управления AdGuard |

**Тесты и бенчмарки** (строки ~1060–1150):
| Функция | Описание |
|---|---|
| `do_test_ip_region()` | Проверка региона IP (все уникальные внешние IPv4) |
| `do_test_censor_geoblock()` | Тест геоблокировки |
| `do_test_yabs()` | Бенчмарк YABS |
| `do_test_bench_sh()` | Бенчмарк bench.sh |
| `do_test_cpu_sysbench()` | Тест CPU |
| `menu_tests()` | Меню тестов |

#### 06_diagnostics.sh — Комплексная диагностика

| Функция | Описание |
|---|---|
| `do_run_diagnostics()` | Выполняет проверки сети/CPU/настроек, выдает отчет и рекомендации по фиксам |
| `run_check()` | Движок для фонового выполнения проверок со спиннером |
| `generate_diagnostic_report()` | Генератор итогового отчета с привязкой к функциям `04_system.sh` |

### Иерархия меню

```
main_menu (main.sh)
├── 1 → menu_system (04_system.sh)
│   ├── 1 → do_update
│   ├── 2 → do_setup_swap
│   ├── 3 → do_network_tuning
│   ├── 4 → menu_ipv6
│   ├── 5 → do_mss_clamp
│   └── 6 → do_hardware_tuning
├── 2 → menu_node (03_node_geo.sh)
│   ├── Установка/Запуск/Обновление ноды
│   └── GeoIP/GeoSite управление
├── 3 → menu_security (05_apps.sh)
│   └── Управление правилами Xray (TrafficGuard)
├── 4 → menu_monitoring (05_apps.sh)
│   ├── menu_vpnguard → Полное управление VPN Guard
│   └── do_install_beszel
├── 5 → menu_apps (05_apps.sh)
│   ├── menu_warp
│   └── menu_adguard
├── 6 → menu_tests (05_apps.sh)
│   └── do_run_diagnostics (06_diagnostics.sh)
└── 7 → do_self_update (main.sh)
```

---

## Часть 2: VPN Guard (vpnguard/)

### Назначение

Мониторинг трафика VPN в реальном времени. Читает access.log Xray, начисляет баллы за подозрительную активность, отправляет алерты в Telegram с AI-анализом.

### Потоки данных

#### Режим демона

```
access.log → tail + fsnotify → readNewLines()
  → "BLOCK"? → ПРОПУСТИТЬ
  → ParseLine() → Entry{Timestamp, SourceIP, Destination, Email}
  → scorer.Add(entry):
      Классификация → spam|ssh|suspicious_port|local_net|whitelist|ip|domain
      Flood detection → events > flood_threshold? → доп. баллы
      score >= threshold? → Alert{}
        → recordAlert() (файл)
        → goroutine: sleep 30s → AI.Analyze() → telegram.SendAlert()
```

#### AI Chain

```
AIChain.Analyze(logs)
  1. Qwen → ok? → "[Qwen] результат"
  2. retry Qwen → ok? → "[Qwen] результат"
  3. Gemini → ok? → "[Gemini] результат"
  4. всё упало → ошибка в алерт
```

#### Отчёт (--report)

```
Все лог-файлы → полный проход →
  Статистика: TCP/UDP, blocked, email↔IP, suspicious ports, offenders
  Suspicious user activity:
    Фильтр: общий RPM >=1, домены >=100 hits И >=1 req/min
    Метки: elevated (>10), high (>30), anomaly (>100), burst
```

### Скоринг

| Приоритет | Категория | Условие | Дефолт баллов |
|---|---|---|---|
| 1 | `spam` | Порт 25/465/587 | 50 |
| 2 | `ssh` | Порт 22 | 15 |
| 3 | `suspicious_port` | Порт 23/445/3389/1433/3306 | 30 |
| 4 | `local_net` | Адрес 192.168.*/10.*/172.16.* | 10 |
| 5 | `whitelist` | Домен в белом списке | 0 |
| 6 | `ip` | Голый IP (не домен) | 3 |
| 7 | `domain` | Всё остальное | 1 |
| + | `flood` | Каждый запрос сверх 200/окно | 10 |

### Конфиг (vpnguard.yaml)

```yaml
node_name: "..."
log_file: "/var/log/remnanode/access.log"
alert_log: "/app/guard_alerts.log"

telegram:
  bot_token: "..."
  chat_id: "..."

ai:
  enabled: true
  prompt: "..."               # Системный промпт (правила и формат ответа)
  qwen_token: "..."           # JWT (основной)
  qwen_url: "https://qwen.aikit.club/v1"
  qwen_model: "qwen3.5-flash"
  gemini_token: "..."         # API key (fallback)

scoring:
  threshold: 800
  window_seconds: 60
  alert_cooldown: 120
  flood_threshold: 200
  points: { domain: 1, ip: 3, whitelist: 0, spam: 50, ... flood: 10 }

whitelist:
  domains: [google, youtube, facebook, vk.com, ...]
  trusted_ip_prefixes: ["149.154.", "91.108.", "87.240.", "95.163.", "93.186.", "95.213.", "95.142.", "185.32.", "185.89.", "185.116.", "130.49.", "62.217.", "94.100.", "155.212.", "178.237.", "217.16.", "217.20.", "217.69.", "5.61.", "79.137.", "83.166.", "87.239.", "90.156.", "128.140.", "161.104.", "176.112.", "178.22.", "188.93.", "212.233.", "5.101.", "5.181.", "5.188.", "31.177.", "37.139.", "45.84.", "45.136.", "83.217.", "83.222.", "84.23.", "85.192.", "87.242.", "89.208.", "89.221.", "91.219.", "91.231.", "94.139.", "109.120.", "146.185.", "185.5.", "185.16.", "185.86.", "185.100.", "185.130.", "185.131.", "185.180.", "185.226.", "185.241.", "193.203.", "195.211.", "212.111.", "213.219.", "217.174.", "195.218.", "92.38.", "185.187.", "194.186.", ...] # Includes comprehensive VKontakte (VK) IPv4 ranges
```

**Конфиг синхронизируется в 3 местах:**
1. `vpnguard/config/config.go` — структуры + дефолты
2. `vpnguard/vpnguard.yaml.example` — шаблон
3. `src/05_apps.sh` → `generate_vpnguard_config()` — генерация при установке

### Docker

```yaml
# /opt/vpnguard/docker-compose.yml
services:
  vpnguard:
    build: ./src/vpnguard
    volumes:
      - ./config/config.yaml:/app/vpnguard.yaml:ro
      - /var/log/remnanode:/var/log/remnanode:ro
      - ./reports:/app/reports
      - ./guard_alerts.log:/app/guard_alerts.log
```

### Формат лога Xray

```
2026/04/26 14:55:57.157 from 178.66.131.73:12729 accepted tcp:domain.com:443 [...-> BLOCK] email: 249
2026/04/26 14:55:59.658 from 178.66.131.73:12790 accepted tcp:google.com:443 [... >> DIRECT] email: 249
```

Строки с `BLOCK` — игнорируются демоном (уже заблокирован).

---

## Пути на сервере

| Путь | Описание |
|---|---|
| `/opt/quick-install/` | Клонированный репозиторий |
| `/opt/quick-install/src/` | Bash-модули |
| `/opt/remnanode/` | Docker Compose ноды Remnawave |
| `/var/log/remnanode/` | Логи Xray (access.log) |
| `/opt/vpnguard/` | Рабочая директория VPN Guard |
| `/opt/vpnguard/config/config.yaml` | Конфиг VPN Guard |
| `/opt/vpnguard/src/vpnguard/` | Исходники Go (после download_vpnguard_source) |
| `/opt/adguardhome/` | AdGuard Home |
| `/usr/local/bin/qi` | Алиас для запуска скрипта |

## Зависимости

**Bash-скрипт**: curl, git, docker, docker compose, ufw, nano, jq, wget  
**VPN Guard (Go)**: `github.com/fsnotify/fsnotify`, `gopkg.in/yaml.v3`
