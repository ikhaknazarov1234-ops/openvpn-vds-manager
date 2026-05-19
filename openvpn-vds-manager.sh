#!/usr/bin/env bash
# OpenVPN VDS Manager
# Ubuntu/Debian helper for installing/removing OpenVPN and managing client .ovpn configs.
# Run as root: sudo bash openvpn-vds-manager.sh

set -Eeuo pipefail

APP_NAME="OpenVPN VDS Manager"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_DIR="/etc/openvpn/server"
CLIENT_DIR="/root/openvpn-clients"
SERVER_CONF="$SERVER_DIR/server.conf"
SERVER_VARS="/etc/openvpn/vds-manager.conf"
NAT_SERVICE="/etc/systemd/system/openvpn-iptables.service"
SYSCTL_CONF="/etc/sysctl.d/99-openvpn-vds.conf"
VPN_SUBNET="10.8.0.0"
VPN_NETMASK="255.255.255.0"
VPN_CIDR="10.8.0.0/24"
DEFAULT_PORT="1194"
DEFAULT_PROTO="udp"
DEFAULT_DNS1="1.1.1.1"
DEFAULT_DNS2="8.8.8.8"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

pause() {
  echo
  read -rp "Нажмите Enter для продолжения..." _ || true
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запустите скрипт от root: sudo bash $0"
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

load_vars() {
  if [[ -f "$SERVER_VARS" ]]; then
    # shellcheck disable=SC1090
    source "$SERVER_VARS"
  fi
  SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
  SERVER_PROTO="${SERVER_PROTO:-$DEFAULT_PROTO}"
  SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-}"
  WAN_IFACE="${WAN_IFACE:-}"
  DNS1="${DNS1:-$DEFAULT_DNS1}"
  DNS2="${DNS2:-$DEFAULT_DNS2}"
}

save_vars() {
  mkdir -p "$(dirname "$SERVER_VARS")"
  cat > "$SERVER_VARS" <<EOF
SERVER_PORT="$SERVER_PORT"
SERVER_PROTO="$SERVER_PROTO"
SERVER_PUBLIC_IP="$SERVER_PUBLIC_IP"
WAN_IFACE="$WAN_IFACE"
DNS1="$DNS1"
DNS2="$DNS2"
VPN_CIDR="$VPN_CIDR"
EOF
  chmod 600 "$SERVER_VARS"
}

is_supported_os() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) return 0 ;;
  esac
  case "${ID_LIKE:-}" in
    *debian*) return 0 ;;
  esac
  return 1
}

require_supported_os() {
  if ! is_supported_os; then
    err "Сейчас поддерживаются только Debian/Ubuntu."
    err "Для CentOS/Alma/Rocky нужно добавить отдельную ветку установки пакетов и firewall."
    exit 1
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    openvpn easy-rsa iptables ca-certificates curl openssl lsb-release
}

detect_wan_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  echo "$ip"
}

valid_ip_or_host() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_proto() {
  [[ "$1" == "udp" || "$1" == "tcp" ]]
}

valid_client_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

openvpn_installed() {
  [[ -f "$SERVER_CONF" && -d "$EASYRSA_DIR/pki" ]]
}

get_easyrsa_bin() {
  if [[ -x "$EASYRSA_DIR/easyrsa" ]]; then
    echo "$EASYRSA_DIR/easyrsa"
  elif command_exists easyrsa; then
    command -v easyrsa
  else
    echo ""
  fi
}

make_easyrsa_dir() {
  rm -rf "$EASYRSA_DIR"
  mkdir -p "$EASYRSA_DIR"

  if command_exists make-cadir; then
    rm -rf "$EASYRSA_DIR"
    make-cadir "$EASYRSA_DIR"
  elif [[ -d /usr/share/easy-rsa ]]; then
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/"
  else
    err "Не найден Easy-RSA. Проверьте пакет easy-rsa."
    exit 1
  fi

  chmod 700 "$EASYRSA_DIR"
}

ask_install_params() {
  load_vars

  local detected_ip detected_iface input
  detected_ip="$(detect_public_ip)"
  detected_iface="$(detect_wan_iface)"

  echo
  info "Параметры OpenVPN. Можно нажимать Enter для значений по умолчанию."

  read -rp "Публичный IP/домен сервера [${detected_ip:-$SERVER_PUBLIC_IP}]: " input || true
  SERVER_PUBLIC_IP="${input:-${detected_ip:-$SERVER_PUBLIC_IP}}"
  while [[ -z "$SERVER_PUBLIC_IP" ]] || ! valid_ip_or_host "$SERVER_PUBLIC_IP"; do
    read -rp "Введите корректный публичный IP или домен: " SERVER_PUBLIC_IP
  done

  read -rp "Порт OpenVPN [$DEFAULT_PORT]: " input || true
  SERVER_PORT="${input:-$DEFAULT_PORT}"
  while ! valid_port "$SERVER_PORT"; do
    read -rp "Введите порт 1-65535: " SERVER_PORT
  done

  read -rp "Протокол udp/tcp [$DEFAULT_PROTO]: " input || true
  SERVER_PROTO="${input:-$DEFAULT_PROTO}"
  SERVER_PROTO="${SERVER_PROTO,,}"
  while ! valid_proto "$SERVER_PROTO"; do
    read -rp "Введите udp или tcp: " SERVER_PROTO
    SERVER_PROTO="${SERVER_PROTO,,}"
  done

  read -rp "Внешний сетевой интерфейс [${detected_iface:-$WAN_IFACE}]: " input || true
  WAN_IFACE="${input:-${detected_iface:-$WAN_IFACE}}"
  while [[ -z "$WAN_IFACE" || ! -d "/sys/class/net/$WAN_IFACE" ]]; do
    read -rp "Интерфейс не найден. Введите внешний интерфейс, например eth0/ens3: " WAN_IFACE
  done

  read -rp "DNS #1 для клиентов [$DEFAULT_DNS1]: " input || true
  DNS1="${input:-$DEFAULT_DNS1}"
  read -rp "DNS #2 для клиентов [$DEFAULT_DNS2]: " input || true
  DNS2="${input:-$DEFAULT_DNS2}"

  save_vars
}

build_pki() {
  local easyrsa
  easyrsa="$(get_easyrsa_bin)"
  [[ -n "$easyrsa" ]] || { err "easyrsa не найден"; exit 1; }

  cd "$EASYRSA_DIR"

  log "Создаю PKI и CA..."
  EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenVPN-VDS-CA" "$easyrsa" init-pki
  EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenVPN-VDS-CA" "$easyrsa" build-ca nopass

  log "Создаю серверный сертификат..."
  EASYRSA_BATCH=1 EASYRSA_REQ_CN="server" "$easyrsa" gen-req server nopass
  EASYRSA_BATCH=1 "$easyrsa" sign-req server server

  log "Генерирую DH и tls-crypt ключ..."
  EASYRSA_BATCH=1 "$easyrsa" gen-dh
  openvpn --genkey secret "$EASYRSA_DIR/ta.key"

  log "Создаю CRL..."
  EASYRSA_BATCH=1 "$easyrsa" gen-crl
}

install_server_files() {
  mkdir -p "$SERVER_DIR" "$CLIENT_DIR" /var/log/openvpn
  chmod 700 "$CLIENT_DIR"

  cp "$EASYRSA_DIR/pki/ca.crt" "$SERVER_DIR/ca.crt"
  cp "$EASYRSA_DIR/pki/issued/server.crt" "$SERVER_DIR/server.crt"
  cp "$EASYRSA_DIR/pki/private/server.key" "$SERVER_DIR/server.key"
  cp "$EASYRSA_DIR/pki/dh.pem" "$SERVER_DIR/dh.pem"
  cp "$EASYRSA_DIR/ta.key" "$SERVER_DIR/ta.key"
  cp "$EASYRSA_DIR/pki/crl.pem" "$SERVER_DIR/crl.pem"
  chmod 600 "$SERVER_DIR/server.key" "$SERVER_DIR/ta.key" "$SERVER_DIR/crl.pem"

  cat > "$SERVER_CONF" <<EOF
port $SERVER_PORT
proto $SERVER_PROTO
dev tun

ca ca.crt
cert server.crt
key server.key
dh dh.pem
crl-verify crl.pem
tls-crypt ta.key

server $VPN_SUBNET $VPN_NETMASK
topology subnet
ifconfig-pool-persist ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"

keepalive 10 120
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256

user nobody
group nogroup
persist-key
persist-tun

status /var/log/openvpn/status.log
verb 3
explicit-exit-notify 1
EOF

  if [[ "$SERVER_PROTO" == "tcp" ]]; then
    sed -i '/explicit-exit-notify/d' "$SERVER_CONF"
  fi
}

enable_forwarding_and_nat() {
  log "Включаю IPv4 forwarding..."
  cat > "$SYSCTL_CONF" <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null

  log "Создаю systemd-сервис для NAT через iptables..."
  cat > "$NAT_SERVICE" <<EOF
[Unit]
Description=OpenVPN iptables NAT rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -t nat -A POSTROUTING -s $VPN_CIDR -o $WAN_IFACE -j MASQUERADE
ExecStart=/usr/sbin/iptables -A FORWARD -s $VPN_CIDR -j ACCEPT
ExecStart=/usr/sbin/iptables -A FORWARD -d $VPN_CIDR -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s $VPN_CIDR -o $WAN_IFACE -j MASQUERADE
ExecStop=/usr/sbin/iptables -D FORWARD -s $VPN_CIDR -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -d $VPN_CIDR -m state --state RELATED,ESTABLISHED -j ACCEPT

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now openvpn-iptables.service
}

start_openvpn_service() {
  log "Запускаю OpenVPN..."
  systemctl daemon-reload
  systemctl enable --now openvpn-server@server.service

  if ! systemctl is-active --quiet openvpn-server@server.service; then
    err "OpenVPN не запустился. Последние строки журнала:"
    journalctl -u openvpn-server@server.service -n 30 --no-pager || true
    exit 1
  fi
}

create_client_ovpn() {
  local client="$1"
  local out="$CLIENT_DIR/$client.ovpn"

  load_vars

  cat > "$out" <<EOF
client
dev tun
proto $SERVER_PROTO
remote $SERVER_PUBLIC_IP $SERVER_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

<ca>
$(cat "$EASYRSA_DIR/pki/ca.crt")
</ca>
<cert>
$(sed -ne '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$EASYRSA_DIR/pki/issued/$client.crt")
</cert>
<key>
$(cat "$EASYRSA_DIR/pki/private/$client.key")
</key>
<tls-crypt>
$(cat "$EASYRSA_DIR/ta.key")
</tls-crypt>
EOF

  chmod 600 "$out"
  log "Клиентский конфиг создан: $out"
}

install_openvpn() {
  require_supported_os

  if openvpn_installed; then
    warn "OpenVPN уже установлен через этот скрипт: $SERVER_CONF"
    return 0
  fi

  ask_install_params
  log "Устанавливаю пакеты..."
  apt_install
  make_easyrsa_dir
  build_pki
  install_server_files
  enable_forwarding_and_nat
  start_openvpn_service

  log "Установка завершена."
  info "Сервер: $SERVER_PUBLIC_IP:$SERVER_PORT/$SERVER_PROTO"
  info "Клиентские конфиги будут сохраняться в $CLIENT_DIR"
  warn "Если у провайдера есть внешний firewall/security group, откройте порт $SERVER_PORT/$SERVER_PROTO."
}

create_client() {
  if ! openvpn_installed; then
    err "OpenVPN ещё не установлен. Сначала выберите пункт установки."
    return 1
  fi

  local client easyrsa
  read -rp "Имя клиента, например iphone или user1: " client
  if ! valid_client_name "$client"; then
    err "Имя может содержать только A-Z, a-z, 0-9, _ и -, длина до 64 символов."
    return 1
  fi

  if [[ -f "$EASYRSA_DIR/pki/issued/$client.crt" ]]; then
    err "Клиент '$client' уже существует."
    return 1
  fi

  easyrsa="$(get_easyrsa_bin)"
  [[ -n "$easyrsa" ]] || { err "easyrsa не найден"; return 1; }

  cd "$EASYRSA_DIR"
  log "Создаю сертификат клиента '$client'..."
  EASYRSA_BATCH=1 EASYRSA_REQ_CN="$client" "$easyrsa" gen-req "$client" nopass
  EASYRSA_BATCH=1 "$easyrsa" sign-req client "$client"

  create_client_ovpn "$client"
}

revoke_client() {
  if ! openvpn_installed; then
    err "OpenVPN ещё не установлен."
    return 1
  fi

  local client easyrsa ovpn
  read -rp "Имя клиента для удаления/отзыва: " client
  if ! valid_client_name "$client"; then
    err "Некорректное имя клиента."
    return 1
  fi

  if [[ ! -f "$EASYRSA_DIR/pki/issued/$client.crt" ]]; then
    warn "Сертификат клиента '$client' не найден. Удалю .ovpn, если он есть."
    rm -f "$CLIENT_DIR/$client.ovpn"
    return 0
  fi

  read -rp "Точно отозвать сертификат '$client'? [y/N]: " confirm
  [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]] || { warn "Отменено."; return 0; }

  easyrsa="$(get_easyrsa_bin)"
  [[ -n "$easyrsa" ]] || { err "easyrsa не найден"; return 1; }

  cd "$EASYRSA_DIR"
  EASYRSA_BATCH=1 "$easyrsa" revoke "$client"
  EASYRSA_BATCH=1 "$easyrsa" gen-crl
  cp "$EASYRSA_DIR/pki/crl.pem" "$SERVER_DIR/crl.pem"
  chmod 600 "$SERVER_DIR/crl.pem"

  ovpn="$CLIENT_DIR/$client.ovpn"
  rm -f "$ovpn"

  systemctl restart openvpn-server@server.service || true
  log "Клиент '$client' отозван. Конфиг удалён: $ovpn"
}

list_clients() {
  if [[ ! -d "$CLIENT_DIR" ]]; then
    warn "Каталог клиентских конфигов не найден: $CLIENT_DIR"
    return 0
  fi

  echo
  info "Клиентские .ovpn в $CLIENT_DIR:"
  shopt -s nullglob
  local files=("$CLIENT_DIR"/*.ovpn)
  if (( ${#files[@]} == 0 )); then
    warn "Пока нет созданных конфигов."
  else
    local f
    for f in "${files[@]}"; do
      echo " - $(basename "$f")"
    done
  fi
  shopt -u nullglob
}

show_status() {
  echo
  info "Статус OpenVPN:"
  if systemctl list-unit-files | grep -q '^openvpn-server@'; then
    systemctl --no-pager --full status openvpn-server@server.service || true
  else
    warn "Unit openvpn-server@server.service не найден."
  fi
  echo
  info "Параметры:"
  load_vars
  echo " SERVER_PUBLIC_IP=$SERVER_PUBLIC_IP"
  echo " SERVER_PORT=$SERVER_PORT"
  echo " SERVER_PROTO=$SERVER_PROTO"
  echo " WAN_IFACE=$WAN_IFACE"
  echo " CLIENT_DIR=$CLIENT_DIR"
}

uninstall_openvpn() {
  if ! openvpn_installed; then
    warn "Установка OpenVPN, созданная этим скриптом, не найдена."
  fi

  echo
  warn "Будут удалены OpenVPN-конфиги, PKI/CA, сертификаты и клиентские .ovpn."
  warn "После этого старые клиентские конфиги восстановить нельзя без резервной копии."
  read -rp "Введите DELETE для подтверждения: " confirm
  [[ "$confirm" == "DELETE" ]] || { warn "Отменено."; return 0; }

  systemctl disable --now openvpn-server@server.service 2>/dev/null || true
  systemctl disable --now openvpn-iptables.service 2>/dev/null || true

  rm -f "$NAT_SERVICE" "$SYSCTL_CONF"
  rm -rf "$EASYRSA_DIR" "$SERVER_DIR" "$CLIENT_DIR" "$SERVER_VARS"
  rm -f /etc/openvpn/server.conf

  systemctl daemon-reload
  sysctl --system >/dev/null || true

  read -rp "Удалить пакеты openvpn/easy-rsa через apt purge? [y/N]: " purge
  if [[ "${purge,,}" == "y" || "${purge,,}" == "yes" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y openvpn easy-rsa || true
    apt-get autoremove -y || true
  fi

  log "Удаление завершено."
}

menu() {
  while true; do
    clear || true
    echo "========================================"
    echo " $APP_NAME"
    echo "========================================"
    echo "1) Установить и настроить OpenVPN"
    echo "2) Удалить OpenVPN"
    echo "3) Создать клиентский .ovpn конфиг"
    echo "4) Удалить/отозвать клиентский конфиг"
    echo "5) Показать список клиентских конфигов"
    echo "6) Показать статус OpenVPN"
    echo "0) Выход"
    echo "----------------------------------------"
    read -rp "Выберите пункт: " choice

    case "$choice" in
      1) install_openvpn; pause ;;
      2) uninstall_openvpn; pause ;;
      3) create_client; pause ;;
      4) revoke_client; pause ;;
      5) list_clients; pause ;;
      6) show_status; pause ;;
      0) exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main() {
  require_root
  load_vars
  menu
}

main "$@"
