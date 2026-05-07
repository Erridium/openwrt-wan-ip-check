#!/bin/sh
# ============================================================
# Установщик check_wan_ip.sh для OpenWRT
# Версия: 2.1 — с интерактивным выбором интерфейса
# ============================================================
set -e

SCRIPT_NAME="check_wan_ip.sh"
SCRIPT_DEST="/usr/bin/${SCRIPT_NAME}"
CONFIG_DEST="/etc/wan-ip-check.conf"
INIT_DEST="/etc/init.d/wan-ip-check"
GITHUB_BASE="https://raw.githubusercontent.com/Erridium/openwrt-wan-ip-check/main"

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${GREEN}${BOLD}=== Установка скрипта проверки WAN IP ====${NC}\n"

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен быть запущен от root${NC}"
    exit 1
fi

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

# --- НОВЫЙ БЛОК: Интерактивный выбор WAN-интерфейса ---
select_wan_interface() {
    echo -e "${CYAN}▶ Определение сетевых интерфейсов...${NC}\n"
    
    # Собираем список интерфейсов с IP и MAC
    # Используем временный файл для хранения данных (POSIX-совместимо)
    TMP_LIST="/tmp/wan-iface-list.$$"
    : > "$TMP_LIST"
    
    local index=1
    local iface ip mac
    
    # Перебираем все интерфейсы из /sys/class/net (исключаем lo)
    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        [ "$iface" = "lo" ] && continue
        
        # Получаем MAC-адрес
        mac=$(cat "${iface_path}/address" 2>/dev/null || echo "N/A")
        
        # Получаем IPv4-адрес (если есть)
        ip=$(ip -4 addr show dev "$iface" 2>/dev/null | \
             grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
             awk '{print $2}' | head -n 1)
        [ -z "$ip" ] && ip="(нет IP)"
        
        # Получаем статус интерфейса
        local state
        state=$(cat "${iface_path}/operstate" 2>/dev/null || echo "unknown")
        local state_marker=""
        case "$state" in
            up) state_marker="${GREEN}▲${NC}" ;;
            *)  state_marker="${RED}▼${NC}" ;;
        esac
        
        # Сохраняем в файл: индекс|имя|ip|mac|state
        printf "%d|%s|%s|%s|%s\n" "$index" "$iface" "$ip" "$mac" "$state" >> "$TMP_LIST"
        index=$(( index + 1 ))
    done
    
    # Выводим таблицу
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
    
    # Определяем наиболее вероятный WAN-интерфейс
    local suggested=""
    # Приоритеты: pppoe-wan > wan > интерфейс с дефолтным маршрутом
    if grep -q "pppoe-wan" "$TMP_LIST" 2>/dev/null; then
        suggested="pppoe-wan"
    elif grep -q "wan\|eth0\.2\|eth1" "$TMP_LIST" 2>/dev/null; then
        suggested=$(grep -E "wan|eth0\.2|eth1" "$TMP_LIST" | head -n 1 | cut -d'|' -f2)
    fi
    
    # Определяем интерфейс с default-маршрутом
    local default_route_iface
    default_route_iface=$(ip route show default 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -n 1)
    [ -n "$default_route_iface" ] && suggested="$default_route_iface"
    
    local choice
    
    # Выводим подсказку с предлагаемым вариантом
    if [ -n "$suggested" ]; then
        local suggested_num
        suggested_num=$(grep "|${suggested}|" "$TMP_LIST" 2>/dev/null | cut -d'|' -f1)
        if [ -n "$suggested_num" ]; then
            echo -e "${CYAN}Рекомендуемый интерфейс: ${BOLD}${suggested}${NC} ${CYAN}(№${suggested_num} — определён по маршруту по умолчанию)${NC}"
        else
            echo -e "${CYAN}Рекомендуемый интерфейс: ${BOLD}${suggested}${NC} ${CYAN}(определён по маршруту по умолчанию)${NC}"
        fi
    fi
    
    # Запрашиваем выбор
    while true; do
        echo ""
        printf "${CYAN}Выберите номер интерфейса для мониторинга${NC}"
        if [ -n "$suggested" ]; then
            printf " ${CYAN}[по умолчанию: ${suggested}]${NC}"
        fi
        printf ": "
        read -r choice
        
        # Если нажали Enter и есть рекомендованный — берём его
        if [ -z "$choice" ] && [ -n "$suggested" ]; then
            WAN_INTERFACE="$suggested"
            break
        fi
        
        # Проверяем, что ввели число
        if ! echo "$choice" | grep -qE '^[0-9]+$'; then
            echo -e "${RED}Пожалуйста, введите номер из списка${NC}"
            continue
        fi
        
        # Ищем интерфейс по номеру
        local selected
        selected=$(grep "^${choice}|" "$TMP_LIST" 2>/dev/null | cut -d'|' -f2)
        if [ -n "$selected" ]; then
            WAN_INTERFACE="$selected"
            break
        else
            echo -e "${RED}Номер ${choice} отсутствует в списке. Попробуйте ещё раз.${NC}"
        fi
    done
    
    # Очистка временного файла
    rm -f "$TMP_LIST"
    
    echo ""
    echo -e "${GREEN}✓ Выбран интерфейс: ${BOLD}${WAN_INTERFACE}${NC}\n"
}

# Вызываем функцию выбора интерфейса
select_wan_interface

# --- Продолжение установки ---

# Скачивание основного скрипта
echo -e "${CYAN}▶ Загрузка ${SCRIPT_NAME}...${NC}"
curl -fsSL "${GITHUB_BASE}/${SCRIPT_NAME}" -o "${SCRIPT_DEST}.tmp" || {
    echo -e "${RED}Ошибка загрузки скрипта${NC}"
    exit 1
}

# Проверка, что скачался именно скрипт, а не страница ошибки
if head -n 1 "${SCRIPT_DEST}.tmp" | grep -q "^#!/bin/sh"; then
    mv "${SCRIPT_DEST}.tmp" "${SCRIPT_DEST}"
    chmod +x "${SCRIPT_DEST}"
    echo -e "${GREEN}✓ Основной скрипт установлен: ${SCRIPT_DEST}${NC}"
else
    rm -f "${SCRIPT_DEST}.tmp"
    echo -e "${RED}Ошибка: Скачанный файл не является скриптом${NC}"
    exit 1
fi

# Создание конфигурации, если не существует
echo ""
echo -e "${CYAN}▶ Создание конфигурации...${NC}"
if [ ! -f "$CONFIG_DEST" ]; then
    cat > "$CONFIG_DEST" << CONFEOF
LOG_FILE="/var/log/wan-ip-check.log"
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
    # Обновляем только WAN_INTERFACE в существующем конфиге
    if grep -q "^WAN_INTERFACE=" "$CONFIG_DEST"; then
        sed -i "s/^WAN_INTERFACE=.*/WAN_INTERFACE=\"${WAN_INTERFACE}\"/" "$CONFIG_DEST"
    else
        echo "WAN_INTERFACE=\"${WAN_INTERFACE}\"" >> "$CONFIG_DEST"
    fi
    echo -e "${GREEN}✓ WAN_INTERFACE обновлён на: ${WAN_INTERFACE}${NC}"
fi

# Установка init-скрипта
echo ""
echo -e "${CYAN}▶ Установка init-скрипта для procd...${NC}"
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

# Включение и запуск сервиса
echo ""
echo -e "${CYAN}▶ Активация автозапуска...${NC}"
"$INIT_DEST" enable
echo -e "${GREEN}✓ Сервис добавлен в автозагрузку${NC}"

echo ""
echo -e "${CYAN}▶ Запуск сервиса...${NC}"
"$INIT_DEST" start
echo -e "${GREEN}✓ Сервис запущен${NC}"

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
echo "  Файл лога:  /var/log/wan-ip-check.log"
echo ""
echo "Конфигурация: /etc/wan-ip-check.conf"
