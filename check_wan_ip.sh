#!/bin/sh

# Config file location
CONFIG_FILE="/etc/wan-ip-check.conf"

# Default values
DEFAULT_WAN_INTERFACE="wan"
DEFAULT_TARGET_NETWORK="109.108.32.0/19"
DEFAULT_UNWANTED_NETWORK="100.64.0.0/10"
DEFAULT_CHECK_INTERVAL=60
DEFAULT_RESTART_DELAY=60
DEFAULT_LOG_FILE="/var/log/wan_ip_check.log"
DEFAULT_MAX_LOG_LINES=100

# Load configuration if exists
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    # Use defaults if no config
    WAN_INTERFACE="$DEFAULT_WAN_INTERFACE"
    TARGET_NETWORK="$DEFAULT_TARGET_NETWORK"
    UNWANTED_NETWORK="$DEFAULT_UNWANTED_NETWORK"
    CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    RESTART_DELAY="$DEFAULT_RESTART_DELAY"
    LOG_FILE="$DEFAULT_LOG_FILE"
    MAX_LOG_LINES="$DEFAULT_MAX_LOG_LINES"
fi

export WAN_INTERFACE TARGET_NETWORK UNWANTED_NETWORK CHECK_INTERVAL RESTART_DELAY LOG_FILE MAX_LOG_LINES

# Variable to track the last logged IP status
LAST_STABLE_IP=""
STABLE_COUNT=0

# logging func with rotation
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="$timestamp - $message"
    
    # Add new entry to the log file
    echo "$log_entry" >> "$LOG_FILE"
    
    # Rotate log file if it exceeds the maximum number of lines
    local current_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$current_lines" -gt "$MAX_LOG_LINES" ]; then
        # Calculate how many lines to remove
        local lines_to_remove=$((current_lines - MAX_LOG_LINES))
        # Create a temporary file with the last MAX_LOG_LINES lines
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
    
    # Also log to system logger
    logger -t "wan-ip-check" "$message"
}

# func that check ip in net without mask of interface
check_ip_in_network() {
    local ip=$1
    local network=$2
    
    # split ip to addr and net
    local network_ip=$(echo $network | cut -d'/' -f1)
    local mask=$(echo $network | cut -d'/' -f2)
    
    # convert IP to numbers for comparison
    local ip_num=$(echo $ip | awk -F'.' '{printf("%d\n", ($1 * 256^3) + ($2 * 256^2) + ($3 * 256) + $4)}')
    local network_num=$(echo $network_ip | awk -F'.' '{printf("%d\n", ($1 * 256^3) + ($2 * 256^2) + ($3 * 256) + $4)}')
    
    # Calculating the mask
    local mask_num=$((0xffffffff << (32 - $mask) & 0xffffffff))
    
    # Checking the network affiliation
    local network_start=$((network_num & mask_num))
    local ip_network=$((ip_num & mask_num))
    
    [ $ip_network -eq $network_start ]
    return $?
}

# The function of getting the current IP WAN interface
get_wan_ip() {
    # We are trying to get an IP through ubus (the preferred method for OpenWRT)
    if command -v ubus >/dev/null 2>&1; then
        ubus call network.interface.$WAN_INTERFACE status | jsonfilter -e '@["ipv4-address"][0].address'
    else
        # Fallback method
        ifconfig $WAN_INTERFACE 2>/dev/null | grep 'inet addr' | awk '{print $2}' | cut -d':' -f2
    fi
}

# The function of restarting the WAN interface
restart_wan() {
    log_message "Restarting the interface $WAN_INTERFACE"
    
    # Stopping the interface
    ifdown $WAN_INTERFACE
    sleep 5
    
    # Launching the interface
    ifup $WAN_INTERFACE
    
    log_message "interface $WAN_INTERFACE restarted, waiting $RESTART_DELAY seconds..."
    sleep $RESTART_DELAY
}

# Main function
main() {
    log_message "Starting the verification of the WAN interface IP address"
    log_message "Target network: $TARGET_NETWORK"
    [ -n "$UNWANTED_NETWORK" ] && log_message "Unwanted network: $UNWANTED_NETWORK"
    log_message "Max log lines: $MAX_LOG_LINES"
    
    while true; do
        # Getting the current IP address
        CURRENT_IP=$(get_wan_ip)
        
        if [ -z "$CURRENT_IP" ]; then
            log_message "Couldn't get the interface's IP address $WAN_INTERFACE"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Checking whether you belong to the target network
        if check_ip_in_network "$CURRENT_IP" "$TARGET_NETWORK"; then
            # IP is in target network - stable state
            if [ "$CURRENT_IP" != "$LAST_STABLE_IP" ]; then
                # IP changed or first check - log it
                log_message "IP address $CURRENT_IP belongs to the network $TARGET_NETWORK"
                LAST_STABLE_IP="$CURRENT_IP"
                STABLE_COUNT=1
            else
                # Same stable IP - log only once every 10 checks to avoid flooding
                STABLE_COUNT=$((STABLE_COUNT + 1))
                if [ $STABLE_COUNT -eq 10 ]; then
                    log_message "IP address $CURRENT_IP still in target network (logged once per 10 checks)"
                    STABLE_COUNT=0
                fi
            fi
        else
            # IP is NOT in target network - always log this
            log_message "IP address $CURRENT_IP DOES NOT belong to the network $TARGET_NETWORK"
            LAST_STABLE_IP=""
            STABLE_COUNT=0
            
            # Additional information: check if the IP belongs to the unwanted network (if defined)
            if [ -n "$UNWANTED_NETWORK" ] && check_ip_in_network "$CURRENT_IP" "$UNWANTED_NETWORK"; then
                log_message "An IP has been detected from the unwanted network: $UNWANTED_NETWORK"
            fi
            
            restart_wan
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# Launching the main function
main