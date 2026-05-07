#!/bin/sh
# ============================================================
# Установщик / Деинсталлятор check_wan_ip.sh для OpenWRT
# Версия: 2.2 — с меню установки, обновления и удаления
# ============================================================
set -e

SCRIPT_NAME="check_wan_ip.sh"
SCRIPT_DEST="/usr/bin/${SCRIPT_NAME}"
CONFIG_DEST="/etc/wan-ip-check.conf"
INIT_DEST="/etc/init.d/wan-ip-check"
LOG_FILE="/var/log/wan-ip-check.log"
LOCK_DIR="/var/lock/wan-ip-check.lock"
GITHUB_BASE="https://raw.githubusercontent.com/Erridium/openwrt-wan-ip-check/main"

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# ВСЕ ФУНКЦИИ (должны быть объявлены до использования)
# ============================================================

# --- Проверка, установлен ли уже скрипт ---
check_installed() {
    [ -f "$SCRIPT_DEST" ] && return 0
    [ -f "$INIT_DEST" ] && return 0
    return 1
}

# --- Выбор WAN-интерфейса ---
select_wan_interface() {
    echo -e "${CYAN}▶ Определение сетевых интерфейсов...${NC}\n"
    
    TMP_LIST="/tmp/wan-iface-list.$$"
    : > "$TMP_LIST"
    
    local index=1
    local iface ip mac
    
    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        [ "$iface" = "lo" ] && continue
        
        mac=$(cat "${iface_path}/address" 2>/dev/null || echo "N/A")
        
        ip=$(ip -4 addr show dev "$iface" 2>/dev/null | \
             grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
             awk '{print $2}' | head -n 1)
        [ -z "$ip" ] && ip="(нет IP)"
        
        local state
        state=$(cat "${iface_path}/operstate" 2>/dev/null || echo "unknown")
        
        printf "%d|%s|%s|%s|%s\n" "$index" "$iface" "$ip" "$mac" "$state" >> "$TMP_LIST"
        index=$(( index + 1 ))
    done
    
    echo -e "${BOLD}Доступные сетевые интерфейсы:${NC}\n"
    printf "  ${BOLD}%-4s %-16s %-18s %-18s %s${NC}\n" "№" "ИНТЕРФЕЙС" "IP-АДРЕС" "MAC-АДРЕС" "СТАТУС"
    printf "  %-4s %-16s %-18s %-18s %s\n" "---" "----------------" "------------------" "------------------" "------"
    
    while IFS='|' read -r idx name ip_addr mac_addr state; do
        local status_icon=""
        [ "$state" = "up" ] && status_icon="${GREEN}активен${NC}" || status_icon="${RED}неактивен${NC}"
        printf "  ${BOLD}%-4s${NC} %-16s %-18s %-18s %b\n" \
               "${idx})" "$name" "$ip_addr" "$mac_addr" "$status_icon"
    done < "$TMP_LIST"
    
    echo ""
    
    # Определяем интерфейс с default-маршрутом
    local suggested
    suggested=$(ip route show default 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -n 1)
    
    if [ -z "$suggested" ]; then
        if grep -q "pppoe-wan" "$TMP_LIST" 2>/dev/null; then
            suggested="pppoe-wan"
        elif grep -q "wan" "$TMP_LIST" 2>/dev/null; then
            suggested="wan"
        fi
    fi
    
    if [ -n "$suggested" ]; then
        local suggested_num
        suggested_num=$(grep "|${suggested}|" "$TMP_LIST" 2>/dev/null | cut -d'|' -f1)
        if [ -n "$suggested_num" ]; then
            echo -e "${CYAN}Рекомендуемый интерфейс: ${BOLD}${suggested}${NC} ${CYAN}(№${suggested_num} — определён по маршруту по умолчанию)${NC}"
        else
            echo -e "${CYAN}Рекомендуемый интерфейс: ${BOLD}${suggested}${NC} ${CYAN}(определён по маршруту по умолчанию)${NC}"
        fi
    fi
    
    local choice
    while true; do
        echo ""
        printf "${CYAN}Выберите номер интерфейса для мониторинга${NC}"
        if [ -n "$suggested" ]; then
            printf " ${CYAN}[по умолчанию: ${suggested}]${NC}"
        fi
        printf ": "
        read -r choice
        
        if [ -z "$choice" ] && [ -n "$suggested" ]; then
            WAN_INTERFACE="$suggested"
            break
        fi
        
        if ! echo "$choice" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}Пожалуйста, введите номер из списка${NC}"
            continue
        fi
        
        local selected
        selected=$(grep "^${choice}|" "$TMP_LIST" 2>/dev/null | cut -d'|' -f2)
        if [ -n "$selected" ]; then
            WAN_INTERFACE="$selected"
            break
        else
            echo -e "${RED}Номер ${choice} отсутствует в списке. Попробуйте ещё раз.${NC}"
        fi
    done
    
    rm -f "$TMP_LIST"
    
    echo ""
    echo -e "${GREEN}✓ Выбран интерфейс: ${BOLD}${WAN_INTERFACE}${NC}\n"
}

# --- Установка ---
do_install() {
    # Проверка зависимостей
    echo -e "${CYAN}▶ Проверка зависимостей...${NC}"
    MISSING=""
    for cmd in ip logger curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            MISSING="${MISSING} ${cmd}"
        fi
    done

    if [ -n "$MISSING" ]; then
        echo -e "${YELLOW}Установка недостающих пакетов:${MISSING}${NC}"
        opkg update
        for pkg in $MISSING; do
            opkg install "$pkg"
        done
    fi
    echo -e "${GREEN}✓ Зависимости проверены${NC}\n"

    # Выбор интерфейса
    select_wan_interface

    # Скачивание основного скрипта
    echo -e "${CYAN}▶ Загрузка ${SCRIPT_NAME}...${NC}"
    curl -fsSL "${GITHUB_BASE}/${SCRIPT_NAME}" -o "${SCRIPT_DEST}.tmp" || {
        echo -e "${RED}Ошибка загрузки скрипта. Проверьте подключение к интернету.${NC}"
        exit 1
    }

    if head -n 1 "${SCRIPT_DEST}.tmp" | grep -q "^#!/bin/sh"; then
        mv "${SCRIPT_DEST}.tmp" "${SCRIPT_DEST}"
        chmod +x "${SCRIPT_DEST}"
        echo -e "${GREEN}✓ Основной скрипт установлен: ${SCRIPT_DEST}${NC}"
    else
        rm -f "${SCRIPT_DEST}.tmp"
        echo -e "${RED}Ошибка: Скачанный файл не является скриптом.${NC}"
        exit 1
    fi

    # Создание конфигурации
    echo ""
    echo -e "${CYAN}▶ Создание конфигурации...${NC}"
    if [ ! -f "$CONFIG_DEST" ]; then
        cat > "$CONFIG_DEST" << CONFEOF
LOG_FILE="${LOG_FILE}"
MAX_LOG_SIZE=512
MAX_LOG_LINES=2000
WAN_INTERFACE="${WAN_INTERFACE}"
TARGET_NETWORKS="100.64.0.0/10 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
CHECK_INTERVAL=120
MAX_RESTARTS=3
RESTART_COOLDOWN=300
LOCK_TIMEOUT=300
CONFEOF
        echo -e "${GREEN}✓ Конфигурация создана: ${CONFIG_DEST}${NC}"
    else
        echo -e "${YELLOW}⚠ Конфигурация уже существует. Обновляю WAN_INTERFACE...${NC}"
        if grep -q "^WAN_INTERFACE=" "$CONFIG_DEST"; then
            sed -i "s/^WAN_INTERFACE=.*/WAN_INTERFACE=\"${WAN_INTERFACE}\"/" "$CONFIG_DEST"
        else
            echo "WAN_INTERFACE=\"${WAN_INTERFACE}\"" >> "$CONFIG_DEST"
        fi
        echo -e "${GREEN}✓ WAN_INTERFACE обновлён на: ${WAN_INTERFACE}${NC}"
    fi

    # Установка init-скрипта
    echo ""
    echo -e "${CYAN}▶ Установка init-скрипта...${NC}"
    cat > "$INIT_DEST" << 'INITEOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1
PROG=/usr/bin/check_wan_ip.sh

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$PROG"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "wan-ip-check"
}

reload_service() {
    stop
    start
}
INITEOF

    chmod +x "$INIT_DEST"
    echo -e "${GREEN}✓ Init-скрипт установлен: ${INIT_DEST}${NC}"

    # Активация и запуск
    echo ""
    echo -e "${CYAN}▶ Активация автозапуска...${NC}"
    "$INIT_DEST" enable
    echo -e "${GREEN}✓ Сервис добавлен в автозагрузку${NC}"

    echo ""
    echo -e "${CYAN}▶ Запуск сервиса...${NC}"
    "$INIT_DEST" start
    echo -e "${GREEN}✓ Сервис запущен${NC}"

    # Финальное резюме
    echo ""
    echo -e "${GREEN}${BOLD}=== Установка завершена успешно! ===${NC}\n"
    echo -e "Мониторинг интерфейса: ${BOLD}${WAN_INTERFACE}${NC}"
    echo ""
    echo "Управление сервисом:"
    echo "  Статус:     /etc/init.d/wan-ip-check status"
    echo "  Запуск:     /etc/init.d/wan-ip-check start"
    echo "  Остановка:  /etc/init.d/wan-ip-check stop"
    echo "  Перезапуск: /etc/init.d/wan-ip-check restart"
    echo "  Лог:        logread -e wan-ip-check"
    echo "  Файл лога:  ${LOG_FILE}"
    echo ""
    echo "Конфигурация: ${CONFIG_DEST}"
    echo ""
    echo "Для обновления или удаления запустите install.sh снова."
}

# --- Обновление (щадящий режим) ---
do_update() {
    echo ""
    echo -e "${CYAN}${BOLD}=== Обновление скрипта check_wan_ip ====${NC}\n"
    
    # Остановка сервиса
    echo -e "${CYAN}▶ Остановка сервиса...${NC}"
    if [ -f "$INIT_DEST" ]; then
        "$INIT_DEST" stop 2>/dev/null || echo -e "${YELLOW}  Сервис не был запущен${NC}"
        echo -e "${GREEN}✓ Сервис остановлен${NC}"
    fi
    
    # Сохраняем текущий интерфейс
    local old_wan_interface="wan"
    if [ -f "$CONFIG_DEST" ]; then
        old_wan_interface=$(grep "^WAN_INTERFACE=" "$CONFIG_DEST" 2>/dev/null | \
                           sed -e 's/^WAN_INTERFACE=//' -e 's/["'\'']//g' || echo "wan")
        echo -e "${GREEN}✓ Текущий интерфейс: ${old_wan_interface}${NC}"
    fi
    
    # Скачивание
    echo -e "${CYAN}▶ Загрузка новой версии...${NC}"
    curl -fsSL "${GITHUB_BASE}/${SCRIPT_NAME}" -o "${SCRIPT_DEST}.tmp" || {
        echo -e "${RED}Ошибка загрузки.${NC}"
        [ -f "$INIT_DEST" ] && "$INIT_DEST" start 2>/dev/null || true
        exit 1
    }
    
    if head -n 1 "${SCRIPT_DEST}.tmp" | grep -q "^#!/bin/sh"; then
        mv "${SCRIPT_DEST}.tmp" "${SCRIPT_DEST}"
        chmod +x "${SCRIPT_DEST}"
        echo -e "${GREEN}✓ Основной скрипт обновлён${NC}"
    else
        rm -f "${SCRIPT_DEST}.tmp"
        echo -e "${RED}Ошибка: Скачанный файл не является скриптом.${NC}"
        [ -f "$INIT_DEST" ] && "$INIT_DEST" start 2>/dev/null || true
        exit 1
    fi
    
    # Обновление init-скрипта
    echo -e "${CYAN}▶ Обновление init-скрипта...${NC}"
    cat > "$INIT_DEST" << 'INITEOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1
PROG=/usr/bin/check_wan_ip.sh

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$PROG"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "wan-ip-check"
}

reload_service() {
    stop
    start
}
INITEOF
    chmod +x "$INIT_DEST"
    echo -e "${GREEN}✓ Init-скрипт обновлён${NC}"
    
    # Миграция конфига
    echo -e "${CYAN}▶ Проверка конфигурации...${NC}"
    if [ -f "$CONFIG_DEST" ]; then
        migrate_param() {
            local param="$1"
            local default_value="$2"
            if ! grep -q "^${param}=" "$CONFIG_DEST" 2>/dev/null; then
                echo "${param}=${default_value}" >> "$CONFIG_DEST"
                echo -e "${YELLOW}  + Добавлен новый параметр: ${param}=${default_value}${NC}"
            fi
        }
        
        migrate_param "MAX_LOG_SIZE" "512"
        migrate_param "MAX_LOG_LINES" "2000"
        migrate_param "TARGET_NETWORKS" '"100.64.0.0/10 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"'
        migrate_param "CHECK_INTERVAL" "120"
        migrate_param "MAX_RESTARTS" "3"
        migrate_param "RESTART_COOLDOWN" "300"
        migrate_param "LOCK_TIMEOUT" "300"
        migrate_param "LOG_FILE" '"/var/log/wan-ip-check.log"'
        
        echo -e "${GREEN}✓ Конфигурация проверена${NC}"
    else
        cat > "$CONFIG_DEST" << CONFEOF
LOG_FILE="/var/log/wan-ip-check.log"
MAX_LOG_SIZE=512
MAX_LOG_LINES=2000
WAN_INTERFACE="${old_wan_interface}"
TARGET_NETWORKS="100.64.0.0/10 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
CHECK_INTERVAL=120
MAX_RESTARTS=3
RESTART_COOLDOWN=300
LOCK_TIMEOUT=300
CONFEOF
        echo -e "${GREEN}✓ Создан новый конфиг${NC}"
    fi
    
    # Запуск
    echo ""
    echo -e "${CYAN}▶ Активация сервиса...${NC}"
    "$INIT_DEST" enable 2>/dev/null || true
    echo -e "${CYAN}▶ Запуск сервиса...${NC}"
    "$INIT_DEST" start
    echo -e "${GREEN}✓ Сервис запущен${NC}"
    
    echo ""
    echo -e "${GREEN}${BOLD}=== Обновление завершено! ===${NC}\n"
    echo -e "Интерфейс: ${BOLD}${old_wan_interface}${NC}"
    echo "Проверьте статус: /etc/init.d/wan-ip-check status"
}

# --- Удаление ---
do_uninstall() {
    local mode="$1"
    
    echo ""
    echo -e "${YELLOW}${BOLD}=== Удаление скрипта check_wan_ip ====${NC}\n"
    
    # Остановка сервиса
    echo -e "${CYAN}▶ Остановка сервиса...${NC}"
    if [ -f "$INIT_DEST" ]; then
        "$INIT_DEST" stop 2>/dev/null || echo -e "${YELLOW}  Сервис не был запущен${NC}"
        "$INIT_DEST" disable 2>/dev/null || echo -e "${YELLOW}  Сервис не был в автозагрузке${NC}"
        echo -e "${GREEN}✓ Сервис остановлен${NC}"
    else
        echo -e "${YELLOW}  Init-скрипт не найден, пропускаю${NC}"
    fi
    
    # Удаление init-скрипта
    echo -e "${CYAN}▶ Удаление init-скрипта...${NC}"
    if [ -f "$INIT_DEST" ]; then
        rm -f "$INIT_DEST"
        echo -e "${GREEN}✓ Удалён: ${INIT_DEST}${NC}"
    fi
    
    # Удаление основного скрипта
    echo -e "${CYAN}▶ Удаление основного скрипта...${NC}"
    if [ -f "$SCRIPT_DEST" ]; then
        rm -f "$SCRIPT_DEST"
        echo -e "${GREEN}✓ Удалён: ${SCRIPT_DEST}${NC}"
    fi
    
    # Удаление lock-файла
    if [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
        echo -e "${GREEN}✓ Удалён lock-файл${NC}"
    fi
    
    # Конфиг и логи
    if [ "$mode" = "full" ]; then
        echo ""
        echo -e "${CYAN}▶ Полное удаление (конфигурация и логи)...${NC}"
        [ -f "$CONFIG_DEST" ] && rm -f "$CONFIG_DEST" && echo -e "${GREEN}✓ Удалён: ${CONFIG_DEST}${NC}"
        [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE" && echo -e "${GREEN}✓ Удалён: ${LOG_FILE}${NC}"
    else
        echo ""
        echo -e "${CYAN}▶ Сохранение конфигурации и логов...${NC}"
        [ -f "$CONFIG_DEST" ] && echo -e "${GREEN}✓ Сохранён: ${CONFIG_DEST}${NC}"
        [ -f "$LOG_FILE" ] && echo -e "${GREEN}✓ Сохранён: ${LOG_FILE}${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}${BOLD}=== Удаление завершено ===${NC}\n"
    
    if [ "$mode" = "keep_config" ]; then
        echo "Для повторной установки запустите install.sh снова."
    fi
    
    exit 0
}


# ============================================================
# ИСПОЛНЯЕМЫЙ КОД (точка входа)
# ============================================================

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен быть запущен от root${NC}"
    exit 1
fi

# Баннер
echo ""
echo -e "${GREEN}${BOLD}=== OpenWRT WAN IP Checker ====${NC}"
echo ""

# Главное меню
if check_installed; then
    echo -e "${YELLOW}Обнаружена существующая установка.${NC}"
    
    if [ -f "$SCRIPT_DEST" ]; then
        current_version=$(grep "Версия:" "$SCRIPT_DEST" 2>/dev/null | head -n 1 | sed 's/.*Версия: *//' || echo "неизвестна")
        echo -e "Текущая версия: ${BOLD}${current_version}${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}Выберите действие:${NC}"
    echo "  1. Обновить скрипт (с сохранением конфигурации и логов)"
    echo "  2. Переустановить с нуля (конфиг будет сохранён как .bak)"
    echo "  3. Удалить скрипт (сохранить конфигурацию и логи)"
    echo "  4. Удалить скрипт полностью (с конфигурацией и логами)"
    echo "  5. Выйти без изменений"
    echo ""
    printf "${CYAN}Ваш выбор [1-5]: ${NC}"
    read -r choice

    case "$choice" in
        1)
            do_update
            ;;
        2)
            [ -f "$INIT_DEST" ] && "$INIT_DEST" stop 2>/dev/null || true
            [ -f "$INIT_DEST" ] && "$INIT_DEST" disable 2>/dev/null || true
            if [ -f "$CONFIG_DEST" ]; then
                cp "$CONFIG_DEST" "${CONFIG_DEST}.bak.$(date +%Y%m%d%H%M%S)"
                echo -e "${YELLOW}Старый конфиг сохранён как .bak${NC}"
                rm -f "$CONFIG_DEST"
            fi
            do_install
            ;;
        3)
            do_uninstall "keep_config"
            ;;
        4)
            do_uninstall "full"
            ;;
        5)
            echo -e "${GREEN}Выход без изменений.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор. Выход.${NC}"
            exit 1
            ;;
    esac
else
    echo -e "${CYAN}Скрипт не установлен. Будет выполнена установка.${NC}\n"
    do_install
fi
