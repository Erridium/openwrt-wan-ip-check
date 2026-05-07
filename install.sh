#!/bin/sh
# ============================================================
# Установщик check_wan_ip.sh для OpenWRT
# ============================================================
set -e

SCRIPT_NAME="check_wan_ip.sh"
SCRIPT_DEST="/usr/bin/${SCRIPT_NAME}"
CONFIG_DEST="/etc/wan-ip-check.conf"
INIT_DEST="/etc/init.d/wan-ip-check"
GITHUB_BASE="https://raw.githubusercontent.com/Erridium/openwrt-wan-ip-check/main"

# Цвета для вывода (безопасные для busybox)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Установка скрипта проверки WAN IP ====${NC}"

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен быть запущен от root${NC}"
    exit 1
fi

# Проверка зависимостей
echo "Проверка зависимостей..."
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

# Скачивание основного скрипта
echo "Загрузка ${SCRIPT_NAME}..."
curl -fsSL "${GITHUB_BASE}/${SCRIPT_NAME}" -o "${SCRIPT_DEST}.tmp" || {
    echo -e "${RED}Ошибка загрузки скрипта${NC}"
    exit 1
}

# Проверка, что скачался именно скрипт, а не страница ошибки
if head -n 1 "${SCRIPT_DEST}.tmp" | grep -q "^#!/bin/sh"; then
    mv "${SCRIPT_DEST}.tmp" "${SCRIPT_DEST}"
    chmod +x "${SCRIPT_DEST}"
    echo -e "${GREEN}Основной скрипт установлен: ${SCRIPT_DEST}${NC}"
else
    rm -f "${SCRIPT_DEST}.tmp"
    echo -e "${RED}Ошибка: Скачанный файл не является скриптом${NC}"
    exit 1
fi

# Создание конфигурации, если не существует
if [ ! -f "$CONFIG_DEST" ]; then
    echo "Создание конфигурационного файла..."
    cat > "$CONFIG_DEST" << 'CONFEOF'
LOG_FILE="/var/log/wan-ip-check.log"
MAX_LOG_SIZE=512
MAX_LOG_LINES=2000
WAN_INTERFACE="wan"
TARGET_NETWORKS="100.64.0.0/10 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
CHECK_INTERVAL=120
MAX_RESTARTS=3
RESTART_COOLDOWN=300
LOCK_TIMEOUT=300
CONFEOF
    echo -e "${GREEN}Конфигурация создана: ${CONFIG_DEST}${NC}"
else
    echo -e "${YELLOW}Конфигурация уже существует, пропускаем${NC}"
fi

# Установка init-скрипта
echo "Установка init-скрипта для procd..."
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

# Включение и запуск сервиса
echo "Активация автозапуска..."
"$INIT_DEST" enable

echo "Запуск сервиса..."
"$INIT_DEST" start

echo ""
echo -e "${GREEN}=== Установка завершена успешно! ===${NC}"
echo ""
echo "Управление сервисом:"
echo "  Статус:     /etc/init.d/wan-ip-check status"
echo "  Запуск:     /etc/init.d/wan-ip-check start"
echo "  Остановка:  /etc/init.d/wan-ip-check stop"
echo "  Перезапуск: /etc/init.d/wan-ip-check restart"
echo "  Лог:        logread -e wan-ip-check"
echo "  Файл лога:  ${LOG_FILE:-/var/log/wan-ip-check.log}"
echo ""
echo "Конфигурация: /etc/wan-ip-check.conf"
