# OpenVPN VDS Manager

Интерактивный bash-скрипт для установки и управления OpenVPN на Ubuntu/Debian VDS/VPS.

## Возможности

- установка и первичная настройка OpenVPN;
- создание PKI/CA через Easy-RSA;
- генерация клиентских `.ovpn` файлов;
- отзыв/удаление клиентских конфигов;
- удаление OpenVPN и созданных конфигов;
- NAT через `iptables` и отдельный `systemd` service;
- интерактивное меню управления;

## Поддержка

Скрипт рассчитан на Ubuntu/Debian с `systemd` и `apt`.

## Быстрый запуск с GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/ikhaknazarov1234-ops/openvpn-vds-manager/main/openvpn-vds-manager.sh -o openvpn-vds-manager.sh
sudo bash openvpn-vds-manager.sh
```

## Локальный запуск

Если файл уже скачан на сервер:

```bash
chmod +x openvpn-vds-manager.sh
sudo bash openvpn-vds-manager.sh
```

## Меню скрипта

После запуска откроется интерактивное меню:

```text
1) Установить и настроить OpenVPN
2) Удалить OpenVPN
3) Создать клиентский .ovpn конфиг
4) Удалить/отозвать клиентский конфиг
5) Показать список клиентских конфигов
6) Показать статус OpenVPN
0) Выход
```

## Где лежат клиентские конфиги

После создания клиента файл будет сохранён здесь:

```bash
/root/openvpn-clients/<client>.ovpn
```

Скачать конфиг на локальный ПК можно через `scp`:

```bash
scp root@SERVER_IP:/root/openvpn-clients/client.ovpn .
```

## Важно

Если у VDS-провайдера есть внешний firewall/security group, открой порт OpenVPN, по умолчанию `1194/udp`.

Перед удалением учитывай, что скрипт удаляет PKI/CA и клиентские конфиги. Без резервной копии старые сертификаты не восстановить.
