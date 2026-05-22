#!/usr/bin/env bash
# ============================================================
#   3proxy — интерактивный установщик
#   Версия: 6.0  |  Ubuntu 20.04 / 22.04 / 24.04
# ============================================================

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'
DIM='\033[2m';     RESET='\033[0m'

# ─── Функции вывода ──────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}${BOLD}[ERR ]${RESET}  $*" >&2; }
die()     { err "$*"; exit 1; }
section() { echo -e "\n${BLUE}${BOLD}━━━  $*  ━━━${RESET}\n"; }
ask()     { echo -e "${YELLOW}${BOLD}  ►  $*${RESET}"; }

banner() {
  echo -e "${BLUE}${BOLD}"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════════════╗
  ║           3proxy  —  установка и настройка              ║
  ║              systemd сервис  |  IPv6 off                ║
  ╚══════════════════════════════════════════════════════════╝
EOF
  echo -e "${RESET}"
}

confirm() {
  local prompt="$1" default="${2:-y}"
  local yn_hint; [[ $default == y ]] && yn_hint="[Y/n]" || yn_hint="[y/N]"
  while true; do
    ask "$prompt $yn_hint"
    read -rp "    → " ans
    ans="${ans:-$default}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     warn "Введите y или n" ;;
    esac
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
}

detect_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' \
    || hostname -I | awk '{print $1}'
}

validate_ip() {
  local ip="$1"
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'; read -ra o <<< "$ip"
  for seg in "${o[@]}"; do [[ $seg -le 255 ]] || return 1; done
  return 0
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

# Спрашивает логин/пароль для одного прокси.
# Записывает результат в глобальные _CRED_USER и _CRED_PASS.
# Возвращает 0 если авторизация включена, 1 если нет.
ask_credentials() {
  local label="$1"
  _CRED_USER=""; _CRED_PASS=""
  if confirm "  Включить авторизацию для ${label}?"; then
    ask "  Логин:"
    read -rp "    → " _CRED_USER
    while [[ -z "$_CRED_USER" ]]; do
      warn "Логин не может быть пустым"; read -rp "    → " _CRED_USER
    done
    ask "  Пароль (ввод скрыт):"
    read -rsp "    → " _CRED_PASS; echo
    while [[ -z "$_CRED_PASS" ]]; do
      warn "Пароль не может быть пустым"; read -rsp "    → " _CRED_PASS; echo
    done
    ok "  Авторизация: пользователь ${_CRED_USER}"
    return 0
  else
    ok "  Авторизация: отключена (открытый прокси)"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════
#  ОПРОС
# ════════════════════════════════════════════════════════════

banner
require_root

# ─── IP сервера ──────────────────────────────────────────────
section "Параметры сервера"

SERVER_IP=$(detect_ip)
info "Обнаружен IP сервера: ${BOLD}${SERVER_IP}${RESET}"
ask "Использовать этот IP? Или введите другой:"
read -rp "    IP [${SERVER_IP}]: " input_ip
SERVER_IP="${input_ip:-$SERVER_IP}"
validate_ip "$SERVER_IP" || die "Некорректный IP: $SERVER_IP"
ok "IP сервера: $SERVER_IP"

# ─── Порты + авторизация ─────────────────────────────────────
section "Порты прокси и авторизация"

# Массивы для HTTP
HTTP_PORTS=()
HTTP_USERS=()   # логин для каждого порта (или "")
HTTP_PASSES=()  # пароль для каждого порта (или "")
_http_next=10000

info "Настройка HTTP-прокси (минимум один порт)"
while true; do
  _num=$(( ${#HTTP_PORTS[@]} + 1 ))
  echo
  info "── HTTP-прокси #${_num} ──────────────────────────"

  # Порт
  while true; do
    ask "Порт HTTP-прокси #${_num} [${_http_next}]:"
    read -rp "    → " _p
    _p="${_p:-${_http_next}}"
    if ! validate_port "$_p"; then warn "Некорректный порт (1–65535)"; continue; fi
    _dup=false
    for _x in "${HTTP_PORTS[@]}"; do [[ "$_x" == "$_p" ]] && _dup=true && break; done
    if $_dup; then warn "Порт $_p уже добавлен"; continue; fi
    break
  done
  HTTP_PORTS+=("$_p")
  ok "HTTP-прокси #${_num}: порт $_p"
  _http_next=$(( _p + 100 ))

  # Авторизация для этого прокси
  if ask_credentials "HTTP-прокси #${_num} :${_p}"; then
    HTTP_USERS+=("$_CRED_USER")
    HTTP_PASSES+=("$_CRED_PASS")
  else
    HTTP_USERS+=("")
    HTTP_PASSES+=("")
  fi

  confirm "Добавить ещё один HTTP-прокси?" n || break
done

ok "HTTP-портов всего: ${#HTTP_PORTS[@]} — ${HTTP_PORTS[*]}"

# Массивы для SOCKS5
SOCKS_PORTS=()
SOCKS_USERS=()
SOCKS_PASSES=()
USE_SOCKS=false

echo
if confirm "Нужен SOCKS5-прокси?" n; then
  USE_SOCKS=true
  _socks_next=20000

  while true; do
    _num=$(( ${#SOCKS_PORTS[@]} + 1 ))
    echo
    info "── SOCKS5 #${_num} ───────────────────────────────"

    while true; do
      ask "Порт SOCKS5 #${_num} [${_socks_next}]:"
      read -rp "    → " _p
      _p="${_p:-${_socks_next}}"
      if ! validate_port "$_p"; then warn "Некорректный порт (1–65535)"; continue; fi
      _dup=false
      for _x in "${SOCKS_PORTS[@]}" "${HTTP_PORTS[@]}"; do
        [[ "$_x" == "$_p" ]] && _dup=true && break
      done
      if $_dup; then warn "Порт $_p уже используется"; continue; fi
      break
    done
    SOCKS_PORTS+=("$_p")
    ok "SOCKS5 #${_num}: порт $_p"
    _socks_next=$(( _p + 100 ))

    if ask_credentials "SOCKS5 #${_num} :${_p}"; then
      SOCKS_USERS+=("$_CRED_USER")
      SOCKS_PASSES+=("$_CRED_PASS")
    else
      SOCKS_USERS+=("")
      SOCKS_PASSES+=("")
    fi

    confirm "Добавить ещё один SOCKS5?" n || break
  done

  ok "SOCKS5-портов всего: ${#SOCKS_PORTS[@]} — ${SOCKS_PORTS[*]}"
else
  ok "SOCKS5 не используется"
fi

# ─── Ограничение по IP клиентов ──────────────────────────────
section "Ограничение доступа по IP"

RESTRICT_IP=false
ALLOWED_IPS=()

if confirm "Ограничить доступ к прокси с определённых IP-адресов?" n; then
  RESTRICT_IP=true
  echo
  info "Вводите IP или подсеть (CIDR) по одному. Пустая строка — завершить ввод."
  info "Примеры: 1.2.3.4  или  10.0.0.0/8  или  192.168.1.0/24"
  echo
  while true; do
    ask "IP / подсеть (Enter — завершить):"
    read -rp "    → " ip_entry
    [[ -z "$ip_entry" ]] && break
    if [[ "$ip_entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
      ALLOWED_IPS+=("$ip_entry")
      ok "Добавлен: $ip_entry"
    else
      warn "Некорректный формат — введите IP или CIDR (например 1.2.3.4 или 10.0.0.0/8)"
    fi
  done

  if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
    warn "Список пуст — доступ будет открыт для всех"
    RESTRICT_IP=false
  else
    ok "Разрешённые IP: ${ALLOWED_IPS[*]}"
  fi
else
  ok "Доступ разрешён со всех IP"
fi

# ─── IPv6 ────────────────────────────────────────────────────
section "IPv6"

DISABLE_IPV6=false
if confirm "Отключить IPv6?" y; then
  DISABLE_IPV6=true
  ok "IPv6 будет отключён"
else
  ok "IPv6 остаётся включённым"
fi

# ─── Сводка ──────────────────────────────────────────────────
section "Сводка — подтвердите установку"

echo -e "  ${BOLD}IP сервера         ${RESET}: $SERVER_IP"
echo
for _i in "${!HTTP_PORTS[@]}"; do
  _auth_info="без авторизации"
  [[ -n "${HTTP_USERS[$_i]}" ]] && _auth_info="пользователь: ${HTTP_USERS[$_i]}"
  echo -e "  ${BOLD}HTTP-прокси #$(( _i+1 ))${RESET}: :${HTTP_PORTS[$_i]}  (${_auth_info})"
done
if $USE_SOCKS; then
  echo
  for _i in "${!SOCKS_PORTS[@]}"; do
    _auth_info="без авторизации"
    [[ -n "${SOCKS_USERS[$_i]}" ]] && _auth_info="пользователь: ${SOCKS_USERS[$_i]}"
    echo -e "  ${BOLD}SOCKS5 #$(( _i+1 ))${RESET}:       :${SOCKS_PORTS[$_i]}  (${_auth_info})"
  done
else
  echo -e "  ${BOLD}SOCKS5             ${RESET}: не используется"
fi
echo
if $RESTRICT_IP; then
  echo -e "  ${BOLD}Доступ с IP        ${RESET}: ${ALLOWED_IPS[*]}"
else
  echo -e "  ${BOLD}Доступ с IP        ${RESET}: все"
fi
echo -e "  ${BOLD}Отключить IPv6     ${RESET}: $( $DISABLE_IPV6 && echo 'да' || echo 'нет' )"
echo

confirm "Начать установку?" || die "Установка отменена."

# ════════════════════════════════════════════════════════════
#  УСТАНОВКА
# ════════════════════════════════════════════════════════════

section "Установка зависимостей"
apt-get update -q || die "apt-get update завершился с ошибкой"
apt-get install -y \
  curl build-essential dnsutils wget \
  net-tools git checkinstall \
  zlib1g-dev libssl-dev openssl \
  || die "Не удалось установить зависимости"
ok "Зависимости установлены"

# ─── Сборка 3proxy ───────────────────────────────────────────
section "Сборка 3proxy"

PROXY3_SRC="/usr/local/src/3proxy"

if [[ -d "$PROXY3_SRC/.git" ]]; then
  info "Репозиторий уже существует — обновляем …"
  git -C "$PROXY3_SRC" pull || warn "git pull завершился с ошибкой, продолжаем с текущей версией"
else
  info "Клонирование репозитория …"
  git clone https://github.com/z3apa3a/3proxy "$PROXY3_SRC" \
    || die "Не удалось клонировать репозиторий 3proxy"
fi

cd "$PROXY3_SRC"
ln -sf Makefile.Linux Makefile
make -j"$(nproc)" || die "Ошибка компиляции 3proxy"

mkdir -p /etc/3proxy /var/log/3proxy
cp "$PROXY3_SRC/bin/3proxy" /usr/bin/3proxy
chmod 755 /usr/bin/3proxy

# Системный пользователь
if ! id proxy3 &>/dev/null; then
  adduser --system --no-create-home --disabled-login --group proxy3 \
    || die "Не удалось создать пользователя proxy3"
fi
PROXY3_UID=$(id -u proxy3)
PROXY3_GID=$(id -g proxy3)
ok "Пользователь proxy3: uid=$PROXY3_UID gid=$PROXY3_GID"

# ─── Генерация конфига ───────────────────────────────────────
section "Создание конфигурации 3proxy"

# Правила allow
build_allow_rules() {
  local src_ips="$1"
  cat <<RULES
deny * * 127.0.0.1
allow ${src_ips} * * 80-88,443,8080-8088,8443,1024-65535 HTTP
allow ${src_ips} * * 80-88,443,8080-8088,8443,1024-65535 HTTPS
allow ${src_ips} * * 53
RULES
}

if $RESTRICT_IP; then
  ALLOW_RULES="deny * * 127.0.0.1"$'\n'
  for ip in "${ALLOWED_IPS[@]}"; do
    ALLOW_RULES+="allow ${ip} * * 80-88,443,8080-8088,8443,1024-65535 HTTP"$'\n'
    ALLOW_RULES+="allow ${ip} * * 80-88,443,8080-8088,8443,1024-65535 HTTPS"$'\n'
    ALLOW_RULES+="allow ${ip} * * 53"$'\n'
  done
  ALLOW_RULES+="deny *"
else
  ALLOW_RULES=$(build_allow_rules "*")
fi

# Заголовок конфига (без глобальной авторизации — у каждого прокси своя)
cat > /etc/3proxy/3proxy.cfg <<EOF
# ─── 3proxy.cfg ──────────────────────────────────────────────
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')

daemon
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

# ─── DNS ─────────────────────────────────────────────────────
nserver 9.9.9.9
nserver 149.112.112.112
nserver 8.8.8.8
nserver 8.8.4.4
nserver 1.1.1.1
nserver 1.0.0.1
nserver 208.67.222.222
nserver 208.67.220.220

# ─── Сеть ────────────────────────────────────────────────────
external ${SERVER_IP}
internal ${SERVER_IP}

maxconn 300

# ─── Правила доступа ─────────────────────────────────────────
${ALLOW_RULES}
EOF

# Файл паролей — собираем всех уникальных пользователей
AUTHFILE="/etc/3proxy/.proxyauth"
> "$AUTHFILE"   # очищаем

write_user_to_authfile() {
  local user="$1" pass="$2"
  # Не дублируем одного пользователя если он уже есть
  if ! grep -q "^${user}:" "$AUTHFILE" 2>/dev/null; then
    local md5hash
    md5hash=$(echo -n "${pass}" | md5sum | awk '{print $1}')
    echo "${user}:CR:${md5hash}" >> "$AUTHFILE"
  fi
}

# ── Блок для одного прокси-слушателя ─────────────────────────
# $1=тип ("proxy"/"socks"), $2=порт, $3=user, $4=pass, $5=номер
write_proxy_block() {
  local type="$1" port="$2" user="$3" pass="$4" num="$5"
  local label; [[ $type == proxy ]] && label="HTTP-прокси #${num}" || label="SOCKS5 #${num}"

  {
    echo ""
    echo "# ─── ${label} (:${port}) ────────────────────────────"
    echo "flush"
    if [[ -n "$user" ]]; then
      write_user_to_authfile "$user" "$pass"
      echo "users /etc/3proxy/.proxyauth"
      echo "auth strong"
      echo "allow ${user}"
    else
      echo "auth none"
    fi
    if [[ $type == proxy ]]; then
      echo "proxy -n -p${port} -a"
    else
      echo "socks -p${port}"
    fi
  } >> /etc/3proxy/3proxy.cfg
}

# ── HTTP-прокси ──────────────────────────────────────────────
for _i in "${!HTTP_PORTS[@]}"; do
  write_proxy_block "proxy" "${HTTP_PORTS[$_i]}" "${HTTP_USERS[$_i]}" "${HTTP_PASSES[$_i]}" "$(( _i+1 ))"
done

# ── SOCKS5 ───────────────────────────────────────────────────
if $USE_SOCKS; then
  for _i in "${!SOCKS_PORTS[@]}"; do
    write_proxy_block "socks" "${SOCKS_PORTS[$_i]}" "${SOCKS_USERS[$_i]}" "${SOCKS_PASSES[$_i]}" "$(( _i+1 ))"
  done
fi

ok "Конфиг: /etc/3proxy/3proxy.cfg"

# ─── Права на файл паролей ───────────────────────────────────
if [[ -s "$AUTHFILE" ]]; then
  section "Файл паролей"
  chown proxy3:proxy3 "$AUTHFILE"
  chmod 400 "$AUTHFILE"
  ok "Файл ${AUTHFILE} создан (пароли хранятся как MD5)"
fi

# ─── Права ───────────────────────────────────────────────────
chown proxy3:proxy3 -R /etc/3proxy /var/log/3proxy
chown proxy3:proxy3 /usr/bin/3proxy
chmod 444 /etc/3proxy/3proxy.cfg

# ─── Очистка iptables ────────────────────────────────────────
section "Очистка iptables"

iptables -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -t nat -F
iptables -t mangle -F
iptables -X

if command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
ok "iptables очищены"

# ─── systemd unit ────────────────────────────────────────────
section "Регистрация systemd-сервиса"

cat > /etc/systemd/system/3proxy.service <<UNIT
[Unit]
Description=3proxy Proxy Server
Documentation=https://github.com/z3apa3a/3proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=proxy3
Group=proxy3
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 /etc/systemd/system/3proxy.service
systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy
ok "Сервис 3proxy запущен и добавлен в автозагрузку"

# ─── Очистка системного мусора ───────────────────────────────
section "Очистка системы"

apt-get purge -y ufw 2>/dev/null || true
apt-get purge -y cloud-init 2>/dev/null || true
rm -rf /etc/cloud /var/lib/cloud 2>/dev/null || true
pro config set apt_news=false 2>/dev/null || true
apt-get -y --purge remove ubuntu-advantage-tools 2>/dev/null || true
sed -i 's/Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades 2>/dev/null || true
apt-get autoremove -y
ok "Очистка завершена"

# ─── sysctl ──────────────────────────────────────────────────
section "Параметры ядра"

SYSCTL_FILE="/etc/sysctl.d/99-3proxy.conf"
cat > "$SYSCTL_FILE" <<SYSCTL
# 3proxy tuning — $(date '+%Y-%m-%d')
vm.swappiness = 10
vm.vfs_cache_pressure = 50
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
SYSCTL

if $DISABLE_IPV6; then
  cat >> "$SYSCTL_FILE" <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL

  if [[ -f /etc/default/grub ]]; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet ipv6.disable=1"/' /etc/default/grub
    sed -i '/^GRUB_CMDLINE_LINUX=/!b; s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0 ipv6.disable=1"/' /etc/default/grub
    update-grub 2>/dev/null || true
  fi
fi

sysctl -p "$SYSCTL_FILE"
ok "sysctl применён"

# ════════════════════════════════════════════════════════════
#  ИТОГ
# ════════════════════════════════════════════════════════════

section "✅  Установка завершена"

echo -e "${BOLD}  Статус сервиса:${RESET}"
systemctl status 3proxy --no-pager -l | head -14
echo

echo -e "${BOLD}  Открытые порты:${RESET}"
_grep_pat=$(printf ':%s|' "${HTTP_PORTS[@]}" "${SOCKS_PORTS[@]}"); _grep_pat="${_grep_pat%|}"
ss -tlpn 2>/dev/null | grep -E "$_grep_pat" || \
  netstat -tlpn 2>/dev/null | grep -E "$_grep_pat" || true
echo

echo -e "${BOLD}  Параметры подключения:${RESET}"
for _i in "${!HTTP_PORTS[@]}"; do
  _auth_info="без авторизации"
  [[ -n "${HTTP_USERS[$_i]}" ]] && _auth_info="логин: ${HTTP_USERS[$_i]}"
  printf "  ${GREEN}HTTP-прокси #%-2s :${RESET}  %s:%s  (%s)\n" \
    "$(( _i+1 ))" "$SERVER_IP" "${HTTP_PORTS[$_i]}" "$_auth_info"
done
if $USE_SOCKS; then
  for _i in "${!SOCKS_PORTS[@]}"; do
    _auth_info="без авторизации"
    [[ -n "${SOCKS_USERS[$_i]}" ]] && _auth_info="логин: ${SOCKS_USERS[$_i]}"
    printf "  ${GREEN}SOCKS5 #%-2s       :${RESET}  %s:%s  (%s)\n" \
      "$(( _i+1 ))" "$SERVER_IP" "${SOCKS_PORTS[$_i]}" "$_auth_info"
  done
fi
if $RESTRICT_IP; then
  echo -e "  ${GREEN}Доступ разрешён :${RESET}  ${ALLOWED_IPS[*]}"
else
  echo -e "  ${YELLOW}Доступ разрешён :${RESET}  все IP"
fi
echo
echo -e "${DIM}  Конфиг  : /etc/3proxy/3proxy.cfg${RESET}"
echo -e "${DIM}  Логи    : journalctl -u 3proxy -f${RESET}"
echo -e "${DIM}  Рестарт : systemctl restart 3proxy${RESET}"
echo
echo -e "${GREEN}${BOLD}  Готово!${RESET}"
echo
