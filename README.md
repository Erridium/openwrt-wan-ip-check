# OpenWRT WAN IP Checker

Скрипт для OpenWRT, который проверяет IP-адрес WAN-интерфейса и перезапускает его, если адрес не принадлежит заданной сети. Полезно, когда провайдер назначает IP из нежелательного диапазона (например, CGNAT).

## Установка одной командой

```sh
curl -fsSL https://raw.githubusercontent.com/ВАШ_ЛОГИН/openwrt-wan-ip-check/main/install.sh | sh
