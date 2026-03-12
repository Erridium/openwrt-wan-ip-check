# OpenWRT WAN IP Checker

Скрипт для OpenWRT, который проверяет IP-адрес WAN-интерфейса и перезапускает его, если адрес не принадлежит заданной сети. Полезно, когда провайдер назначает IP из нежелательного диапазона (например, CGNAT).

## Установка одной командой

```sh
curl -fsSL https://raw.githubusercontent.com/Erridium/openwrt-wan-ip-check/main/install.sh | sh
```
## Просмотр логов
```sh
logread -f | grep wan-ip-check
```
или
```sh
tail -f /var/log/wan_ip_check.log
```
