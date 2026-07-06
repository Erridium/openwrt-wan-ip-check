#!/bin/sh
# ============================================================
# wan-ip-check.sh - Мониторинг и сброс CGNAT-адресов для OpenWRT
# Версия: 2.5
# ============================================================

set -o pipefail

# --- Конфигурация по умолчанию (переопределяется из конфиг-файла) ---
CONFIG_FILE="/etc/wan-ip-check.conf"
LOG_FILE="/var/log/wan-ip-check.log"
MAX_LOG_SIZE=512
MAX_LOG_LINES=2000
WAN_INTERFACE="wan"
WAN_DEVICE=""
TARGET_NETWORKS="100.64.0.0/10 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
CHECK_INTERVAL=120
MAX_RESTARTS=3
RESTART_COOLDOWN=300
LOCK_TIMEOUT=300

# --- Lock-файл ---
LOCK_FILE="/var/lock/wan-ip-check.lock"

# --- Проверка зависимостей ---
check_dependencies() {
    local missing=""
    for cmd in ip logger; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done
    if [ -n "$missing" ]; then
        echo "ОШИБКА: Отсутствуют необходимые утилиты:${missing}" >&2
        echo "Установите: opkg install iputils-logger" >&2
        exit 1
    fi
}

# --- Парсинг конфигурационного файла (key=value) ---
parse_config() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        # Пропускаем пустые строки и комментарии
        case "$key" in
            ""|\#*) continue ;;
        esac

        # Удаляем пробелы, кавычки и комментарии в значении
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//' -e 's/[[:space:]]*#.*$//')

        case "$key" in
            LOG_FILE)         LOG_FILE="$value" ;;
            MAX_LOG_SIZE)     MAX_LOG_SIZE="$value" ;;
            MAX_LOG_LINES)    MAX_LOG_LINES="$value" ;;
            WAN_INTERFACE)    WAN_INTERFACE="$value" ;;
            WAN_DEVICE)       WAN_DEVICE="$value" ;;
            TARGET_NETWORKS)  TARGET_NETWORKS="$value" ;;
            CHECK_INTERVAL)   CHECK_INTERVAL="$value" ;;
            MAX_RESTARTS)     MAX_RESTARTS="$value" ;;
            RESTART_COOLDOWN) RESTART_COOLDOWN="$value" ;;
            LOCK_TIMEOUT)     LOCK_TIMEOUT="$value" ;;
            *)
                logger -t "wan-ip-check" -p "daemon.warn" "Неизвестный параметр в конфиге: $key" 2>/dev/null
                ;;
        esac
    done < "$file"
}

# --- Улучшенное логирование ---
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    local log_entry

    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    #log_entry="[${timestamp}] [$(echo "$level" | tr '[:lower:]' '[:upper:]')] ${message}"
    log_entry="[${timestamp}] [$(echo "$level" | tr 'a-z' 'A-Z')] ${message}"

    # Системный лог
    logger -t "wan-ip-check" -p "daemon.${level}" "${message}" 2>/dev/null || true

    # Файл лога
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            echo "[${timestamp}] [ERROR] Невозможно создать директорию лога: ${log_dir}" >&2
            return 1
        }
    fi

    echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || {
        echo "[${timestamp}] [ERROR] Не удалось записать в файл лога: ${LOG_FILE}" >&2
        return 1
    }

    rotate_logs_if_needed
}

# --- Ротация логов ---
rotate_logs_if_needed() {
    [ ! -f "$LOG_FILE" ] && return 0

    local log_size_kb log_lines need_rotation=0

    log_size_kb=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    log_size_kb=$(( log_size_kb / 1024 ))
    log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)

    [ "$log_size_kb" -gt "$MAX_LOG_SIZE" ] 2>/dev/null && need_rotation=1
    [ "$log_lines" -gt "$MAX_LOG_LINES" ] 2>/dev/null && need_rotation=1

    if [ "$need_rotation" -eq 1 ]; then
        local temp_log="${LOG_FILE}.tmp.$$"
        local keep_lines=$(( MAX_LOG_LINES / 2 ))
        [ "$keep_lines" -lt 100 ] && keep_lines=100

        tail -n "$keep_lines" "$LOG_FILE" > "$temp_log" 2>/dev/null && {
            mv "$temp_log" "$LOG_FILE" 2>/dev/null || {
                rm -f "$temp_log" 2>/dev/null
                echo "[$(date "+%Y-%m-%d %H:%M:%S")] [ERROR] Ошибка ротации лога" >> "$LOG_FILE" 2>/dev/null
            }
        } || {
            rm -f "$temp_log" 2>/dev/null
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [ERROR] Ошибка создания временного файла при ротации" >&2
        }

        if [ -f "$LOG_FILE" ]; then
            log_size_kb=$(wc -c < "$LOG_FILE" 2>/dev/null)
            log_size_kb=$(( log_size_kb / 1024 ))
            if [ "$log_size_kb" -gt "$(( MAX_LOG_SIZE * 2 ))" ]; then
                tail -n 100 "$LOG_FILE" > "${LOG_FILE}.emergency" 2>/dev/null && \
                mv "${LOG_FILE}.emergency" "$LOG_FILE" 2>/dev/null
                echo "[$(date "+%Y-%m-%d %H:%M:%S")] [WARN] Экстренная ротация лога" >> "$LOG_FILE" 2>/dev/null
            fi
        fi

        local rot_msg="Ротация логов выполнена (size=${log_size_kb}K, lines=${log_lines})"
        logger -t "wan-ip-check" -p "daemon.info" "${rot_msg}" 2>/dev/null || true
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] ${rot_msg}" >> "$LOG_FILE" 2>/dev/null
    fi
}

# --- Получение WAN IP (современный метод) ---
get_wan_ip() {
    local wan_ip=""

    # Метод 1: через ip без фильтрации scope
    if command -v ip >/dev/null 2>&1; then
        wan_ip=$(ip -4 addr show dev "$WAN_INTERFACE" 2>/dev/null | \
                 grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
                 awk '{print $2}' | head -n 1)
        if [ -n "$wan_ip" ] && [ "$wan_ip" != "127.0.0.1" ]; then
            echo "$wan_ip"
            return 0
        fi
    fi

    # Метод 2: внешний сервис (fallback)
    for service in "ifconfig.co" "ipinfo.io/ip" "icanhazip.com"; do
        if command -v curl >/dev/null 2>&1; then
            wan_ip=$(curl -fsSL --interface "$WAN_INTERFACE" "$service" 2>/dev/null)
            if [ -n "$wan_ip" ] && echo "$wan_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "$wan_ip"
                return 0
            fi
        fi
    done

    return 1
}

# --- Проверка IP на принадлежность к CGNAT/частным сетям ---
is_private_or_cgnat_ip() {
    local ip="$1"
    local networks="$2"
    local network

    # Используем ipcalc если доступен
    if command -v ipcalc >/dev/null 2>&1; then
        for network in $networks; do
            if ipcalc -c "$ip" "$network" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi

    # Запасной метод: разбиваем IP на октеты (POSIX-совместимо)
    local o1 o2 o3 o4
    o1=$(echo "$ip" | cut -d. -f1)
    o2=$(echo "$ip" | cut -d. -f2)
    o3=$(echo "$ip" | cut -d. -f3)
    o4=$(echo "$ip" | cut -d. -f4)

    # Проверка на корректность октетов
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        case "$octet" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$octet" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done

    for network in $networks; do
        case "$network" in
            100.64.0.0/10)
                [ "$o1" -eq 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ] && return 0
                ;;
            10.0.0.0/8)
                [ "$o1" -eq 10 ] && return 0
                ;;
            172.16.0.0/12)
                [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ] && return 0
                ;;
            192.168.0.0/16)
                [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ] && return 0
                ;;
        esac
    done

    return 1
}

# --- Перезапуск WAN-интерфейса ---
restart_wan() {
    local device="${WAN_DEVICE:-$WAN_INTERFACE}"
    log_message "info" "Перезапуск WAN-интерфейса (${device})..."

    if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
        local ifdown_out ifdown_rc ifup_out ifup_rc

        ifdown_out=$(ifdown "$device" 2>&1)
        ifdown_rc=$?
        log_message "info" "ifdown ${device} (rc=${ifdown_rc}): ${ifdown_out}"

        sleep 2

        ifup_out=$(ifup "$device" 2>&1)
        ifup_rc=$?
        log_message "info" "ifup ${device} (rc=${ifup_rc}): ${ifup_out}"

        sleep 10

        if [ "$ifdown_rc" -ne 0 ] || [ "$ifup_rc" -ne 0 ]; then
            log_message "warn" "ifdown/ifup завершились с ошибками (ifdown_rc=${ifdown_rc}, ifup_rc=${ifup_rc})"
            return 1
        fi

        return 0
    else
        log_message "error" "Команды ifdown/ifup не найдены"
        return 1
    fi
}

# --- Lock-файл с проверкой целостности ---
acquire_lock() {
    if mkdir "$LOCK_FILE" 2>/dev/null; then
        echo "$$" > "${LOCK_FILE}/pid"
        echo "$(date +%s)" > "${LOCK_FILE}/timestamp"
        trap 'release_lock' EXIT INT TERM HUP
        return 0
    fi

    local lock_pid lock_timestamp current_time
    lock_pid=$(cat "${LOCK_FILE}/pid" 2>/dev/null || echo "0")
    lock_timestamp=$(cat "${LOCK_FILE}/timestamp" 2>/dev/null || echo "0")
    current_time=$(date +%s)

    if [ "$lock_pid" -gt 1 ] 2>/dev/null && kill -0 "$lock_pid" 2>/dev/null; then
        local proc_cmd
        proc_cmd=$(cat "/proc/${lock_pid}/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
        if echo "$proc_cmd" | grep -q "wan-ip-check"; then
            log_message "warn" "Скрипт уже выполняется (PID: ${lock_pid})"
            return 1
        fi
    fi

    if [ $(( current_time - lock_timestamp )) -gt "$LOCK_TIMEOUT" ]; then
        log_message "warn" "Обнаружен устаревший lock-файл. Принудительное снятие."
        release_lock
        acquire_lock
        return $?
    fi

    log_message "error" "Lock-файл существует, но процесс ${lock_pid} не найден. Ожидание."
    return 1
}

release_lock() {
    if [ -d "$LOCK_FILE" ]; then
        rm -rf "$LOCK_FILE" 2>/dev/null
    fi
    trap - EXIT INT TERM HUP
}

# --- Основной цикл ---
main_loop() {
    local last_stable_ip=""
    local restart_count=0

    log_message "info" "Скрипт wan-ip-check.sh запущен (интерфейс: ${WAN_INTERFACE})"

    while true; do
        if ! acquire_lock; then
            sleep 60
            continue
        fi

        local current_ip
        current_ip=$(get_wan_ip)

        if [ -z "$current_ip" ]; then
            log_message "error" "Не удалось получить IP-адрес интерфейса ${WAN_INTERFACE}"
            release_lock
            sleep 30
            continue
        fi

        if [ "$current_ip" != "$last_stable_ip" ]; then
            log_message "info" "Текущий WAN IP: ${current_ip}"

            if is_private_or_cgnat_ip "$current_ip" "$TARGET_NETWORKS"; then
                log_message "warn" "Обнаружен приватный/CGNAT-адрес (${current_ip})"

                if [ "$restart_count" -ge "$MAX_RESTARTS" ]; then
                    log_message "error" "Достигнут лимит перезапусков (${MAX_RESTARTS}). Охлаждение на ${RESTART_COOLDOWN} сек."
                    release_lock
                    sleep "$RESTART_COOLDOWN"
                    restart_count=0
                    continue
                fi

                if restart_wan; then
                    restart_count=$(( restart_count + 1 ))
                    log_message "info" "Перезапуск выполнен (попытка ${restart_count}/${MAX_RESTARTS})"
                    sleep 15
                    release_lock
                    continue
                else
                    log_message "error" "Ошибка при перезапуске WAN"
                fi
            else
                last_stable_ip="$current_ip"
                restart_count=0
                log_message "info" "Получен публичный IP: ${current_ip}"
            fi
        fi

        release_lock
        sleep "$CHECK_INTERVAL"
    done
}

# --- Точка входа ---
check_dependencies
parse_config "$CONFIG_FILE"

case "${1:-}" in
    rotate)
        rotate_logs_if_needed
        echo "Ротация логов выполнена."
        exit 0
        ;;
    status)
        current_ip=$(get_wan_ip)
        echo "Статус скрипта wan-ip-check:"
        echo "  Интерфейс:      ${WAN_INTERFACE}"
        echo "  Текущий IP:     ${current_ip:-недоступен}"
        echo "  Лог-файл:       ${LOG_FILE} ($(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) строк)"
        if [ -d "$LOCK_FILE" ]; then
            echo "  Lock:           захвачен (PID: $(cat "${LOCK_FILE}/pid" 2>/dev/null))"
        else
            echo "  Lock:           свободен"
        fi
        exit 0
        ;;
    test-restart)
        device="${WAN_DEVICE:-$WAN_INTERFACE}"
        echo "=== Тест перезапуска WAN-интерфейса ==="
        echo "Интерфейс (IP): ${WAN_INTERFACE}"
        echo "Устройство (ifdown/ifup): ${device}"
        echo ""
        ip_before=$(get_wan_ip)
        echo "IP до перезапуска: ${ip_before:-недоступен}"
        echo ""
        log_message "info" "Тестовый перезапуск запущен вручную"
        restart_wan
        rc=$?
        echo ""
        echo "Код возврата restart_wan: ${rc}"
        ip_after=$(get_wan_ip)
        echo "IP после перезапуска: ${ip_after:-недоступен}"
        echo ""
        if [ "$ip_before" = "$ip_after" ]; then
            echo "ВНИМАНИЕ: IP не изменился!"
        else
            echo "IP успешно изменён."
        fi
        echo ""
        echo "Последние записи лога:"
        tail -10 "$LOG_FILE" 2>/dev/null || echo "(лог пуст)"
        exit $rc
        ;;
    *)
        main_loop
        ;;
esac
