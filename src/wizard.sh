#!/usr/bin/env bash
# =============================================================================
#  vless-setup.sh — мастер установки VLESS (REALITY + XHTTP) с нуля: на выходе vless://-ссылка и мини-панель.
#
#  Две схемы (выбираются первым вопросом):
#    1) ОДИН сервер:   клиент ─► сервер ─► Cloudflare WARP ─► интернет   (рунет — напрямую с сервера)
#    2) ДВА сервера:   клиент ─► российский (вход) ─► зарубежный ─► Cloudflare WARP ─► интернет
#                      (рунет — напрямую с российского; IP зарубежного нигде не светится)
#
#  Запуск на своём компьютере (macOS / Linux):    bash vless-setup.sh
#  Скрипт сам спросит всё нужное: схему, IP серверов и их SSH-порты (если сменил 22 на другой — укажи его),
#  токен и поддомены DuckDNS. Порт VPN — 443 (как у обычного сайта); если он занят, скрипт предложит другой.
#  Серверы — чистые Debian 12/13 или Ubuntu 22.04+, доступ root по SSH (пароль спросят по разу на сервер).
#
#  ПЕРЕД ЗАПУСКОМ: на duckdns.org заведи по одному поддомену на каждый сервер (имена любые).
#  Через токен поддомены создать нельзя — только на сайте. Старые поддомены можно использовать снова.
#
#  Если порт на сервере занят (старый VPN, Caddy и т.п.), скрипт объяснит, чем занят, и предложит, как исправить.
#  Повторный запуск безопасен: ключи и сертификаты сохраняются, ссылка остаётся прежней.
#  Ответы запоминаются в файле vless-setup.last рядом со скриптом — в следующий раз будут подставлены по умолчанию.
#
#  Для опытных (необязательно): ответы можно передать переменными и не отвечать на вопросы, например
#    MODE=1 S_IP=203.0.113.10 S_LOC=foreign S_SUB=myhome CONN_PORT=443 AUTO=1 bash vless-setup.sh
#  Переменные: MODE(1|2) S_IP S_LOC(ru|foreign) S_SSH_PORT S_SUB  RU_IP RELAY_IP RU_SSH_PORT RELAY_SSH_PORT RU_SUB RELAY_SUB
#              CONN_PORT RELAY_PORT DUCKDNS_TOKEN EXIT_MODE(warp|direct) FP(firefox|chrome|…) AUTO=1 (брать ответы по умолчанию)
#
#  Токен DuckDNS сохраняется в vless-setup.last (права 600) — не выкладывай этот файл и vless-link.txt.
# =============================================================================
set -euo pipefail

# ------------------------------- ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ ------------------------
SCRIPT_VERSION="@@VERSION@@"
BUILTIN_TOKEN=""                                     # токен DuckDNS по умолчанию (пусто — спросить); можно ввести на шаге 4 или передать DUCKDNS_TOKEN=...
SAVED_TOKEN="$BUILTIN_TOKEN"                         # если на шаге 4 введён другой — он запомнится в vless-setup.last
DEF_RU_IP=""                                         # IP по умолчанию (подставляются из vless-setup.last после первого запуска)
DEF_RELAY_IP=""
SSH_USER="${SSH_USER:-root}"
EXIT_MODE="${EXIT_MODE:-warp}"
FP="${FP:-firefox}"
RELAY_PORT="${RELAY_PORT:-443}"
AUTO="${AUTO:-0}"
LAST_FILE="${LAST_FILE:-./vless-setup.last}"
VPN_RE='xray|x-ui|3x-ui|sing-box|hysteria|v2ray|trojan|ss-server|ssserver|marzban'
# -----------------------------------------------------------------------------

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_b=$'\033[1;36m'; c_0=$'\033[0m'
say()  { printf '\n%s== %s%s\n' "$c_g" "$*" "$c_0" >&2; }
note() { printf '%s! %s%s\n' "$c_y" "$*" "$c_0" >&2; }
die()  { printf '\n%sОШИБКА: %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

for t in ssh curl tee sed tr grep cut awk; do command -v "$t" >/dev/null 2>&1 || die "на этом компьютере не найдена команда $t"; done
case "$EXIT_MODE" in warp|direct) ;; *) die "EXIT_MODE должен быть warp или direct" ;; esac
printf '%s' "$FP" | grep -Eq '^[a-z0-9]+$' || die "странное значение FP"

# прошлые ответы — как значения по умолчанию
DEF_MODE=""; DEF_S_IP=""; DEF_S_LOC=""; DEF_S_SSH_PORT="22"; DEF_S_SUB=""
DEF_RU_SSH_PORT="22"; DEF_RELAY_SSH_PORT="22"; DEF_RU_SUB=""; DEF_RELAY_SUB=""
if [ -f "$LAST_FILE" ]; then
  # shellcheck disable=SC1090
  . "$LAST_FILE" 2>/dev/null || note "не удалось прочитать $LAST_FILE — продолжаю без прошлых ответов"
fi

# ------------------------------- ВВОД -----------------------------------------
ask_line() { # $1 подсказка -> строка (читаем с терминала, даже если stdin занят)
  local v=""
  printf '%s' "$1" >&2
  if [ "${VLESS_SETUP_STDIN:-0}" != 1 ] && { exec 3</dev/tty; } 2>/dev/null; then   # VLESS_SETUP_STDIN=1 — ответы из stdin (для тестов)
    IFS= read -r v <&3 || { exec 3<&-; return 1; }
    exec 3<&-
  else
    IFS= read -r v || return 1
  fi
  printf '%s' "$v"
}
# shellcheck disable=SC2018,SC2019  # имена поддоменов и ответы — латиница, нужен именно ASCII
norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \r\t'; }
ask_yn() { # $1 вопрос, $2 ответ по умолчанию y|n -> 0 = да
  local d="${2:-y}" v hint="(y — да, n — нет) [Y/n]"
  [ "$d" = n ] && hint="(y — да, n — нет) [y/N]"
  if [ "$AUTO" = 1 ]; then [ "$d" = y ]; return; fi
  while :; do
    v="$(ask_line "$1 $hint: ")" || die "нет ввода"
    v="$(norm "$v")"
    case "$v" in
      "") [ "$d" = y ]; return ;;
      y|yes|д|да|Д|Да|ДА) return 0 ;;
      n|no|н|нет|Н|Нет|НЕТ) return 1 ;;
      *) note "Ответь y (да) или n (нет)" ;;
    esac
  done
}
ask_choice() { # $1 вопрос, далее варианты -> номер (1..N)
  local q="$1"; shift
  local n=$# i=1 o v
  printf '\n%s%s%s\n' "$c_b" "$q" "$c_0" >&2
  for o in "$@"; do printf '  %d) %s\n' "$i" "$o" >&2; i=$((i + 1)); done
  while :; do
    v="$(ask_line "Введи номер (1–$n): ")" || die "нет ввода"
    v="$(norm "$v")"
    if [[ $v =~ $RE_NUM ]] && [ "$v" -ge 1 ] && [ "$v" -le "$n" ]; then printf '%s' "$v"; return 0; fi
    note "Нужно число от 1 до $n"
  done
}
RE_IP='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
RE_NUM='^[0-9]+$'
RE_PORT='^[0-9]{1,5}$'
RE_SUB='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
RE_FQDN='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$'
RE_TOKEN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
is_ip() {
  local o
  [[ $1 =~ $RE_IP ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done
  case "$1" in 0.*|127.*|255.*|22[4-9].*|23[0-9].*) return 1 ;; esac
  return 0
}
is_private_ip() {
  case "$1" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) return 0 ;; esac
  return 1
}
is_port() { [[ $1 =~ $RE_PORT ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }
ask_ip() { # $1 вопрос, $2 по умолчанию
  local v p="$1"
  [ -n "${2:-}" ] && p="$p [$2]"
  if [ "$AUTO" = 1 ] && [ -n "${2:-}" ]; then printf '%s' "$2"; return 0; fi
  while :; do
    v="$(ask_line "$p: ")" || die "нет ввода"
    v="$(norm "$v")"; [ -z "$v" ] && v="${2:-}"
    if [ -z "$v" ]; then note "Нужен IPv4-адрес сервера, например 203.0.113.10 (он есть в письме или панели хостера)"; continue; fi
    if ! is_ip "$v"; then note "«$v» не похоже на IPv4-адрес. Пример: 203.0.113.10"; continue; fi
    if is_private_ip "$v"; then
      note "$v — внутренний адрес: из интернета к нему не подключиться. Нужен внешний (публичный) IP сервера."
      ask_yn "Всё равно использовать $v?" n || continue
    fi
    printf '%s' "$v"; return 0
  done
}
ask_port() { # $1 вопрос, $2 по умолчанию
  local v
  if [ "$AUTO" = 1 ]; then printf '%s' "$2"; return 0; fi
  while :; do
    v="$(ask_line "$1 [$2]: ")" || die "нет ввода"
    v="$(norm "$v")"; [ -z "$v" ] && v="$2"
    if is_port "$v"; then printf '%s' "$((10#$v))"; return 0; fi
    note "Порт — это число от 1 до 65535"
  done
}
ask_sub() { # $1 вопрос, $2 по умолчанию (может быть пусто)
  local v p="$1"
  [ -n "${2:-}" ] && p="$p [$2]"
  if [ "$AUTO" = 1 ] && [ -n "${2:-}" ]; then printf '%s' "$2"; return 0; fi
  while :; do
    v="$(ask_line "$p: ")" || die "нет ввода"
    v="$(norm "$v")"; v="${v%.duckdns.org}"; [ -z "$v" ] && v="${2:-}"
    if [ -z "$v" ]; then note "Нужно имя поддомена — то, что ты создал на duckdns.org (без .duckdns.org), например myhome42"; continue; fi
    if [[ $v =~ $RE_SUB ]] || [[ $v =~ $RE_FQDN ]]; then printf '%s' "$v"; return 0; fi
    note "В имени можно только латинские буквы, цифры и дефис (свой полный домен тоже подойдёт)"
  done
}
ask_token() {
  local v p="Токен DuckDNS"
  [ -n "$SAVED_TOKEN" ] && p="$p (Enter — оставить сохранённый …${SAVED_TOKEN: -4})"
  if [ "$AUTO" = 1 ] && [ -n "$SAVED_TOKEN" ]; then printf '%s' "$SAVED_TOKEN"; return 0; fi
  while :; do
    v="$(ask_line "$p: ")" || die "нет ввода"
    v="$(norm "$v")"; [ -z "$v" ] && v="$SAVED_TOKEN"
    if [[ $v =~ $RE_TOKEN ]]; then printf '%s' "$v"; return 0; fi
    note "Токен выглядит так: 1a2b3c4d-1111-2222-3333-444455556666 (он написан на duckdns.org вверху страницы после входа)"
  done
}
port_hint() { # $1 порт -> предупреждение, если не 443
  if [ "$1" != 443 ]; then
    note "Порт $1 работает, но 443 лучше: на нём VPN неотличим от обычного HTTPS-сайта. Другой порт бери, только если 443 занят."
  fi
}
mkdom() { case "$1" in *.*) printf '%s 0' "$1" ;; *) printf '%s.duckdns.org 1' "$1" ;; esac; }

# ------------------------------- МАСТЕР ---------------------------------------
printf '\n%s╭──────────────────────────────────────────────────────────────╮%s\n' "$c_b" "$c_0" >&2
printf '%s│   Установка VLESS (REALITY + XHTTP) — пошаговый мастер        │%s\n' "$c_b" "$c_0" >&2
printf '%sверсия %s%s\n' "$c_b" "$SCRIPT_VERSION" "$c_0" >&2
printf '%s╰──────────────────────────────────────────────────────────────╯%s\n' "$c_b" "$c_0" >&2
printf 'Отвечай на вопросы. В квадратных скобках — ответ по умолчанию: просто нажми Enter.\n' >&2

if [ -z "${MODE:-}" ]; then
  if [ "$AUTO" = 1 ] && [ -n "$DEF_MODE" ]; then MODE="$DEF_MODE"; else
    MODE="$(ask_choice "Шаг 1. Сколько серверов будем использовать?" \
      "Один сервер — проще и быстрее (если одного сервера заблокируют, VPN встанет)" \
      "Два сервера: российский (вход) + зарубежный (выход) — устойчивее к блокировкам")"
  fi
fi
case "$MODE" in 1|2) ;; *) die "MODE должен быть 1 или 2" ;; esac

if [ "$MODE" = 1 ]; then
  if [ -z "${S_LOC:-}" ]; then
    if [ "$AUTO" = 1 ] && [ -n "$DEF_S_LOC" ]; then S_LOC="$DEF_S_LOC"; else
      loc_choice="$(ask_choice "Шаг 2. Где находится сервер?" \
        "За границей — VPN работает напрямую; со временем IP сервера могут заблокировать" \
        "В России — подключение к российскому IP (его почти не блокируют), выход в интернет через Cloudflare WARP")"
      if [ "$loc_choice" = 2 ]; then S_LOC=ru; else S_LOC=foreign; fi
    fi
  fi
  case "$S_LOC" in ru|foreign) ;; *) die "S_LOC должен быть ru или foreign" ;; esac
  if [ "$S_LOC" = ru ] && [ "$EXIT_MODE" = direct ]; then die "для одного российского сервера нужен WARP: с EXIT_MODE=direct заблокированные сайты не откроются"; fi
  say "Шаг 3. Сервер"
  [ -n "${S_IP:-}" ] || S_IP="$(ask_ip "IP-адрес сервера" "$DEF_S_IP")"
  is_ip "$S_IP" || die "неверный IP: $S_IP"
  [ -n "${S_SSH_PORT:-}" ] || S_SSH_PORT="$(ask_port "SSH-порт сервера — по нему скрипт зайдёт на сервер (если не меняли — 22)" "$DEF_S_SSH_PORT")"
else
  say "Шаг 2. Российский сервер — к нему подключаешься ты"
  [ -n "${RU_IP:-}" ] || RU_IP="$(ask_ip "IP российского сервера" "$DEF_RU_IP")"
  is_ip "$RU_IP" || die "неверный IP: $RU_IP"
  [ -n "${RU_SSH_PORT:-}" ] || RU_SSH_PORT="$(ask_port "SSH-порт российского сервера (если не меняли — 22)" "$DEF_RU_SSH_PORT")"
  say "Шаг 3. Зарубежный сервер — через него выход в интернет"
  [ -n "${RELAY_IP:-}" ] || RELAY_IP="$(ask_ip "IP зарубежного сервера" "$DEF_RELAY_IP")"
  is_ip "$RELAY_IP" || die "неверный IP: $RELAY_IP"
  [ "$RU_IP" != "$RELAY_IP" ] || die "у российского и зарубежного серверов должны быть разные IP"
  [ -n "${RELAY_SSH_PORT:-}" ] || RELAY_SSH_PORT="$(ask_port "SSH-порт зарубежного сервера (если не меняли — 22)" "$DEF_RELAY_SSH_PORT")"
fi
CONN_PORT="${CONN_PORT:-443}"   # порт VPN: 443 — как у обычного сайта; другой предложим, только если 443 занят
is_port "$CONN_PORT" || die "неверный порт VPN: $CONN_PORT"
is_port "$RELAY_PORT" || die "неверный RELAY_PORT: $RELAY_PORT"
[ "$CONN_PORT" != 80 ] || die "порт 80 нужен для получения сертификата — выбери другой порт VPN (лучше 443)"
port_hint "$CONN_PORT"

say "Шаг 4. DuckDNS"
if [ -z "${DUCKDNS_TOKEN:-}" ]; then DUCKDNS_TOKEN="$(ask_token)"; fi
printf 'Нужен поддомен на duckdns.org для каждого сервера (создаётся вручную на сайте, можно взять старый).\n' >&2
if [ "$MODE" = 1 ]; then
  [ -n "${S_SUB:-}" ] || S_SUB="$(ask_sub "Поддомен для сервера (без .duckdns.org)" "$DEF_S_SUB")"
  S_SUB="$(norm "$S_SUB")"; S_SUB="${S_SUB%.duckdns.org}"
  read -r S_DOMAIN S_DUCK <<<"$(mkdom "$S_SUB")"
else
  [ -n "${RU_SUB:-}" ] || RU_SUB="$(ask_sub "Поддомен для российского сервера (без .duckdns.org)" "$DEF_RU_SUB")"
  [ -n "${RELAY_SUB:-}" ] || RELAY_SUB="$(ask_sub "Поддомен для зарубежного сервера (без .duckdns.org)" "$DEF_RELAY_SUB")"
  RU_SUB="$(norm "$RU_SUB")"; RU_SUB="${RU_SUB%.duckdns.org}"
  RELAY_SUB="$(norm "$RELAY_SUB")"; RELAY_SUB="${RELAY_SUB%.duckdns.org}"
  read -r RU_DOMAIN RU_DUCK <<<"$(mkdom "$RU_SUB")"
  read -r RELAY_DOMAIN RELAY_DUCK <<<"$(mkdom "$RELAY_SUB")"
  [ "$RU_DOMAIN" != "$RELAY_DOMAIN" ] || die "для двух серверов нужны два РАЗНЫХ поддомена"
fi

# ------------------------------- СВОДКА ---------------------------------------
printf '\n%sПроверь, всё ли верно:%s\n' "$c_b" "$c_0" >&2
if [ "$MODE" = 1 ]; then
  if [ "$S_LOC" = ru ]; then loc_txt="в России"; else loc_txt="за границей"; fi
  printf '  Схема:          один сервер (%s) → %s\n' "$loc_txt" "$( [ "$EXIT_MODE" = warp ] && echo 'Cloudflare WARP' || echo 'прямой выход' )" >&2
  printf '  Сервер:         %s   (SSH-порт %s)\n' "$S_IP" "$S_SSH_PORT" >&2
  printf '  Домен:          %s\n' "$S_DOMAIN" >&2
else
  printf '  Схема:          два сервера: российский → зарубежный → %s\n' "$( [ "$EXIT_MODE" = warp ] && echo 'Cloudflare WARP' || echo 'прямой выход' )" >&2
  printf '  Российский:     %s   (SSH-порт %s)   домен %s\n' "$RU_IP" "$RU_SSH_PORT" "$RU_DOMAIN" >&2
  printf '  Зарубежный:     %s   (SSH-порт %s)   домен %s\n' "$RELAY_IP" "$RELAY_SSH_PORT" "$RELAY_DOMAIN" >&2
fi
printf '  Порт VPN:       %s (к нему подключается клиент)\n' "$CONN_PORT" >&2
printf '  Токен DuckDNS:  …%s\n' "${DUCKDNS_TOKEN: -4}" >&2
ask_yn "Начинаем?" y || die "отменено — ничего не изменено"

# запоминаем ответы для следующего запуска (файл с токеном сразу создаётся закрытым)
old_umask="$(umask)"; umask 077
{
  printf '# ответы прошлого запуска vless-setup.sh — подставляются по умолчанию\n'
  printf 'DEF_MODE=%q\n' "$MODE"
  if [ "$MODE" = 1 ]; then
    printf 'DEF_S_IP=%q\nDEF_S_LOC=%q\nDEF_S_SSH_PORT=%q\nDEF_S_SUB=%q\n' "$S_IP" "$S_LOC" "$S_SSH_PORT" "$S_SUB"
  else
    printf 'DEF_RU_IP=%q\nDEF_RELAY_IP=%q\nDEF_RU_SSH_PORT=%q\nDEF_RELAY_SSH_PORT=%q\nDEF_RU_SUB=%q\nDEF_RELAY_SUB=%q\n' \
      "$RU_IP" "$RELAY_IP" "$RU_SSH_PORT" "$RELAY_SSH_PORT" "$RU_SUB" "$RELAY_SUB"
  fi
  if [ "$DUCKDNS_TOKEN" != "$BUILTIN_TOKEN" ]; then printf 'SAVED_TOKEN=%q\n' "$DUCKDNS_TOKEN"; fi
  # прежние значения другой схемы не теряем
  if [ "$MODE" = 1 ]; then
    printf 'DEF_RU_IP=%q\nDEF_RELAY_IP=%q\nDEF_RU_SUB=%q\nDEF_RELAY_SUB=%q\nDEF_RU_SSH_PORT=%q\nDEF_RELAY_SSH_PORT=%q\n' \
      "$DEF_RU_IP" "$DEF_RELAY_IP" "$DEF_RU_SUB" "$DEF_RELAY_SUB" "$DEF_RU_SSH_PORT" "$DEF_RELAY_SSH_PORT"
  else
    printf 'DEF_S_IP=%q\nDEF_S_LOC=%q\nDEF_S_SUB=%q\nDEF_S_SSH_PORT=%q\n' "$DEF_S_IP" "$DEF_S_LOC" "$DEF_S_SUB" "$DEF_S_SSH_PORT"
  fi
} > "$LAST_FILE" 2>/dev/null || note "не удалось сохранить ответы в $LAST_FILE — в следующий раз придётся ввести их заново"
umask "$old_umask"
chmod 600 "$LAST_FILE" 2>/dev/null || true

# ------------------------------- SSH ------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vlsetup.XXXXXX")"
CP_A="/tmp/vlsetup-$$-a.sock"; CP_B="/tmp/vlsetup-$$-b.sock"
SSH_BASE=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=40 -o ConnectTimeout=25)
cleanup() {
  ssh -o "ControlPath=$CP_B" -O exit x >/dev/null 2>&1 || true
  ssh -o "ControlPath=$CP_A" -O exit x >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ----------------------- серверные скрипты (вшиты в этот файл) ---------------
cat > "$WORK/relay.sh" <<'__RELAY_SCRIPT_END__'
@@RELAY_SCRIPT@@
__RELAY_SCRIPT_END__

cat > "$WORK/ru.sh" <<'__RU_SCRIPT_END__'
@@RU_SCRIPT@@
__RU_SCRIPT_END__

cat > "$WORK/single.sh" <<'__SINGLE_SCRIPT_END__'
@@SINGLE_SCRIPT@@
__SINGLE_SCRIPT_END__

ssh_hint="Проверь IP, SSH-порт и пароль. Если сервер переустанавливали — выполни  ssh-keygen -R <IP>  и запусти снова."

# A — сервер, к которому подключается клиент (единственный или российский); B — зарубежный в схеме из двух
A_IP=""; A_PORT=""; B_IP=""; B_PORT=""; B_MODE=via-a
if [ "$MODE" = 1 ]; then A_IP="$S_IP"; A_PORT="$S_SSH_PORT"; else A_IP="$RU_IP"; A_PORT="$RU_SSH_PORT"; B_IP="$RELAY_IP"; B_PORT="$RELAY_SSH_PORT"; fi
sshA() { ssh "${SSH_BASE[@]}" -o ControlMaster=no -o "ControlPath=$CP_A" -p "$A_PORT" "$SSH_USER@$A_IP" "$@"; }
sshB() {
  if [ "$B_MODE" = via-a ]; then
    ssh "${SSH_BASE[@]}" -o ControlMaster=no -o "ControlPath=$CP_B" \
      -o "ProxyCommand=ssh -o ControlMaster=no -o ControlPath=$CP_A -p $A_PORT -W %h:%p $SSH_USER@$A_IP" \
      -p "$B_PORT" "$SSH_USER@$B_IP" "$@"
  else
    ssh "${SSH_BASE[@]}" -o ControlMaster=no -o "ControlPath=$CP_B" -p "$B_PORT" "$SSH_USER@$B_IP" "$@"
  fi
}
os_check() { # $1 = функция ssh, $2 = подпись -> печатает "arch id"
  local pre arch id
  # shellcheck disable=SC2016  # команда выполняется на сервере, $ID раскрывается там
  pre="$($1 'uname -m; . /etc/os-release; echo "$ID"' </dev/null)" || die "$2 не выполнил команду"
  arch="$(printf '%s\n' "$pre" | sed -n '1p')"; id="$(printf '%s\n' "$pre" | sed -n '2p')"
  case "$id" in debian|ubuntu) ;; *) die "на сервере «$2» система «$id» — нужен Debian или Ubuntu" ;; esac
  case "$arch" in x86_64|amd64|aarch64|arm64) ;; *) die "на сервере «$2» процессор $arch — поддерживаются x86_64 и arm64" ;; esac
  printf '%s %s' "$arch" "$id"
}

if [ "$MODE" = 1 ]; then
  say "Захожу на сервер $A_IP (если спросит пароль — это пароль root)"
else
  say "Захожу на российский сервер $A_IP (если спросит пароль — это пароль root)"
fi
ssh "${SSH_BASE[@]}" -o ControlMaster=yes -o ControlPersist=7200 -o "ControlPath=$CP_A" -p "$A_PORT" -Nf "$SSH_USER@$A_IP" \
  || die "не удалось зайти по SSH на $SSH_USER@$A_IP:$A_PORT. $ssh_hint"
A_INFO="$(os_check sshA "$A_IP")" || exit 1
read -r A_ARCH A_OS <<<"$A_INFO"

if [ "$MODE" = 2 ]; then
  say "Проверяю, виден ли зарубежный сервер С РОССИЙСКОГО (по этому пути пойдёт трафик)"
  if ! sshA "timeout 10 bash -c 'exec 3<>/dev/tcp/$B_IP/$B_PORT' 2>/dev/null" </dev/null; then
    die "с российского сервера не открывается $B_IP:$B_PORT. Либо зарубежный сервер выключен, либо его IP уже заблокирован из России — попроси у хостера новый IP и запусти скрипт снова."
  fi
  say "Захожу на зарубежный сервер $B_IP через российский (если спросит пароль — это пароль root ЗАРУБЕЖНОГО сервера)"
  if ! ssh "${SSH_BASE[@]}" -o ControlMaster=yes -o ControlPersist=7200 -o "ControlPath=$CP_B" \
       -o "ProxyCommand=ssh -o ControlMaster=no -o ControlPath=$CP_A -p $A_PORT -W %h:%p $SSH_USER@$A_IP" \
       -p "$B_PORT" -Nf "$SSH_USER@$B_IP"; then
    note "через российский сервер зайти не вышло — пробую напрямую"
    B_MODE=direct
    ssh "${SSH_BASE[@]}" -o ControlMaster=yes -o ControlPersist=7200 -o "ControlPath=$CP_B" -p "$B_PORT" -Nf "$SSH_USER@$B_IP" \
      || die "не удалось зайти по SSH на $SSH_USER@$B_IP:$B_PORT. $ssh_hint"
  fi
  B_INFO="$(os_check sshB "$B_IP")" || exit 1
  read -r B_ARCH B_OS <<<"$B_INFO"
  say "Оба сервера на связи (российский: $A_OS/$A_ARCH, зарубежный: $B_OS/$B_ARCH)"
else
  say "Сервер на связи ($A_OS/$A_ARCH)"
fi

# ------------------------------- ПРОВЕРКА ПОРТОВ (с выбором действий) ----------
read -r -d '' PF_SCRIPT <<'__PF_END__' || true
for p in "$@"; do
  l="$(ss -ltnp "sport = :$p" 2>/dev/null | grep LISTEN | head -n1)"
  [ -n "$l" ] || continue
  info="$(printf '%s\n' "$l" | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 \2/p')"
  read -r name pid <<<"$info"
  exe="$(readlink -f "/proc/${pid:-0}/exe" 2>/dev/null || true)"
  printf '%s %s %s\n' "$p" "${name:-?}" "${exe:-?}"
done
__PF_END__
preflight() { # $1 функция ssh, $2 подпись, $3 имя переменной с портом VLESS -> PF_FORCE=0|1
  local sshfn="$1" label="$2" pvar="$3" out port name exe other newp
  PF_FORCE=0
  while :; do
    other=""
    out="$(printf '%s\n' "$PF_SCRIPT" | "$sshfn" bash -s -- 80 "${!pvar}" 2>/dev/null || true)"
    while read -r port name exe <&4; do
      [ -n "${port:-}" ] || continue
      case "$exe" in /opt/vless-xray/xray*) continue ;; esac            # наша прошлая установка — разберётся сама
      if [ "$port" = 80 ] && [ "$name" = nginx ]; then continue; fi       # nginx (скорее всего наш) — проверит серверная часть
      if [ "$port" = 80 ] && [ "$name" = caddy ]; then
        say "На сервере $label порт 80 занят Caddy (через него работает какой-то сайт)."
        printf '  Порт 80 нужен для сертификата. Скрипт перенесёт HTTP Caddy на 8080 (с копией конфига и откатом при сбое),\n  а nginx будет пересылать ему всё, что не для VPN, — сайты на Caddy продолжат работать.\n' >&2
        ask_yn "Перенести Caddy с порта 80?" y || die "без порта 80 не получить сертификат. Освободи порт 80 и запусти скрипт снова."
        continue
      fi
      if printf '%s' "$name" | grep -Eiq "$VPN_RE"; then
        say "На сервере $label порт $port занят старым VPN («$name»)."
        if ask_yn "Остановить его и отключить автозапуск? (старые ссылки этого VPN перестанут работать)" y; then
          PF_FORCE=1
        else
          if [ "$port" = 80 ]; then die "порт 80 нужен для сертификата. Освободи его и запусти скрипт снова."; fi
          other="$name"
        fi
        continue
      fi
      if [ "$port" = 80 ]; then
        die "на сервере $label порт 80 занят программой «$name» ($exe). Он нужен для сертификата Let's Encrypt: останови её или перенеси на другой порт и запусти скрипт снова."
      fi
      other="$name"
    done 4<<<"$out"
    if [ -n "$other" ]; then
      say "На сервере $label порт ${!pvar} занят программой «$other»."
      if [ "$AUTO" != 1 ] && ask_yn "Выбрать для VPN другой порт?" y; then
        newp="$(ask_port "Новый порт (например 8443 или 2053)" 8443)"
        [ "$newp" != 80 ] || { note "80 нельзя — он нужен для сертификата"; continue; }
        printf -v "$pvar" '%s' "$newp"
        port_hint "$newp"
        continue
      fi
      die "порт ${!pvar} занят — освободи его или запусти скрипт снова с другим портом."
    fi
    break
  done
}

if [ "$MODE" = 1 ]; then
  preflight sshA "$A_IP" CONN_PORT; FORCE_A="$PF_FORCE"
else
  preflight sshA "$A_IP (российский)" CONN_PORT; FORCE_A="$PF_FORCE"
  preflight sshB "$B_IP (зарубежный)" RELAY_PORT; FORCE_B="$PF_FORCE"
fi

# ------------------------------- DuckDNS (проверка с этого компьютера) ---------
duck_try() { # $1 поддомен  $2 ip  -> 0 = OK, 1 = KO, 2 = нет связи с DuckDNS
  local r
  r="$(curl -s --max-time 15 "https://www.duckdns.org/update?domains=$1&token=$DUCKDNS_TOKEN&ip=$2" 2>/dev/null || true)"
  case "$r" in OK) return 0 ;; KO) return 1 ;; *) return 2 ;; esac
}
check_duck() { # $1 поддомен  $2 ip  $3 домен
  local rc=0
  duck_try "$1" "$2" || rc=$?
  case "$rc" in
    0) say "DuckDNS: $3 → $2" ;;
    1) die "DuckDNS ответил KO для «$1»: такого поддомена нет в аккаунте с этим токеном (или токен неверный). Создай поддомен на https://www.duckdns.org и запусти скрипт ещё раз." ;;
    *) note "с этого компьютера DuckDNS недоступен — обновлю запись с сервера" ;;
  esac
}
if [ "$MODE" = 1 ]; then
  if [ "$S_DUCK" = 1 ]; then check_duck "$S_SUB" "$S_IP" "$S_DOMAIN"; fi
else
  if [ "$RU_DUCK" = 1 ]; then check_duck "$RU_SUB" "$RU_IP" "$RU_DOMAIN"; fi
  if [ "$RELAY_DUCK" = 1 ]; then check_duck "$RELAY_SUB" "$RELAY_IP" "$RELAY_DOMAIN"; fi
fi

run_on() { # $1 = A|B  $2 = файл скрипта  $3 = строки export  $4 = имя лога
  local who="$1" file="$2" envl="$3" logn="$4" remote cmd
  remote="/root/.vless-setup/run-$logn.sh"
  cmd="mkdir -p /root/.vless-setup && chmod 700 /root/.vless-setup && cat > $remote && chmod 700 $remote && bash $remote </dev/null"
  if [ "$who" = B ]; then
    { printf '%s\n' "$envl"; cat "$file"; } | sshB "$cmd" 2>&1 | tee "$WORK/$logn.log"
  else
    { printf '%s\n' "$envl"; cat "$file"; } | sshA "$cmd" 2>&1 | tee "$WORK/$logn.log"
  fi
}
getv() { grep -a "^@@$2=" "$WORK/$1.log" | tail -n1 | cut -d= -f2- | tr -d '\r' || true; }

if [ "$MODE" = 1 ]; then
  # =============================== СХЕМА 1: ОДИН СЕРВЕР ===============================
  say "Настраиваю сервер $S_IP. Займёт несколько минут"
  ENV_S="$(printf 'export %s=%q\n' \
    S_IP "$S_IP" S_DOMAIN "$S_DOMAIN" S_SUB "$S_SUB" S_DUCK "$S_DUCK" S_LOC "$S_LOC" CONN_PORT "$CONN_PORT" \
    DUCKDNS_TOKEN "$DUCKDNS_TOKEN" EXIT_MODE "$EXIT_MODE" FORCE "$FORCE_A" FP "$FP")"
  run_on A "$WORK/single.sh" "$ENV_S" single || die "настройка сервера не завершилась (причина выше)"
  LINK="$(getv single LINK)"; PANEL_PORT="$(getv single PANEL_PORT)"
  [ -n "$LINK" ] || die "сервер не вернул ссылку (смотри вывод выше)"
  PANEL_HOST="$S_IP"; PANEL_SSH_PORT="$S_SSH_PORT"
else
  # =============================== СХЕМА 2: ДВА СЕРВЕРА ===============================
  say "ШАГ 1/3. Зарубежный сервер $RELAY_IP (ретранслятор + WARP). Займёт несколько минут"
  ENV_RELAY="$(printf 'export %s=%q\n' \
    RELAY_IP "$RELAY_IP" RU_IP "$RU_IP" RELAY_DOMAIN "$RELAY_DOMAIN" RU_DOMAIN "$RU_DOMAIN" \
    RELAY_SUB "$RELAY_SUB" RU_SUB "$RU_SUB" RELAY_DUCK "$RELAY_DUCK" RU_DUCK "$RU_DUCK" RELAY_LISTEN_PORT "$RELAY_PORT" \
    DUCKDNS_TOKEN "$DUCKDNS_TOKEN" EXIT_MODE "$EXIT_MODE" FORCE "$FORCE_B" FP "$FP" RU_ARCH "$A_ARCH")"
  run_on B "$WORK/relay.sh" "$ENV_RELAY" relay || die "настройка зарубежного сервера не завершилась (причина выше)"
  RELAY_UUID="$(getv relay RELAY_UUID)"; RELAY_PUB="$(getv relay RELAY_PUB)"; RELAY_SID="$(getv relay RELAY_SID)"; RELAY_PATH="$(getv relay RELAY_PATH)"
  if [ -z "$RELAY_UUID" ] || [ -z "$RELAY_PUB" ] || [ -z "$RELAY_SID" ] || [ -z "$RELAY_PATH" ]; then die "зарубежный сервер не вернул параметры (смотри вывод выше)"; fi

  say "ШАГ 2/3. Передаю файлы Xray с зарубежного сервера на российский (GitHub из РФ может не открываться)"
  sshA 'mkdir -p /root/.vless-setup && chmod 700 /root/.vless-setup' </dev/null
  sshB 'cat /root/.vless-setup/ru-bundle.tgz' </dev/null | sshA 'cat > /root/.vless-setup/ru-bundle.tgz' || die "не удалось передать файлы между серверами"
  sshB 'rm -f /root/.vless-setup/ru-bundle.tgz' </dev/null || true

  say "ШАГ 3/3. Российский сервер $RU_IP (вход + самопроверка + панель)"
  ENV_RU="$(printf 'export %s=%q\n' \
    RELAY_IP "$RELAY_IP" RU_IP "$RU_IP" RELAY_DOMAIN "$RELAY_DOMAIN" RU_DOMAIN "$RU_DOMAIN" \
    RELAY_UUID "$RELAY_UUID" RELAY_PUB "$RELAY_PUB" RELAY_SID "$RELAY_SID" RELAY_PATH "$RELAY_PATH" RELAY_PORT "$RELAY_PORT" \
    CONN_PORT "$CONN_PORT" EXIT_MODE "$EXIT_MODE" FORCE "$FORCE_A" FP "$FP")"
  run_on A "$WORK/ru.sh" "$ENV_RU" ru || die "настройка российского сервера не завершилась (причина выше)"
  LINK="$(getv ru LINK)"; PANEL_PORT="$(getv ru PANEL_PORT)"
  [ -n "$LINK" ] || die "российский сервер не вернул ссылку (смотри вывод выше)"
  PANEL_HOST="$RU_IP"; PANEL_SSH_PORT="$RU_SSH_PORT"
fi


( umask 077; printf '%s\n' "$LINK" > ./vless-link.txt )
printf '\n%s======================================================================%s\n' "$c_g" "$c_0"
printf '%s ГОТОВО. Твоя ссылка (сохранена в ./vless-link.txt):%s\n\n%s\n\n' "$c_g" "$c_0" "$LINK"
printf ' Формат: VLESS + REALITY + XHTTP — клиент должен уметь XHTTP (ядро Xray 24.11+).\n'
if [ -n "$PANEL_PORT" ]; then
  printf '\n Панель (ссылка, состояние, проверка VPN, смена UUID). Наружу она не открыта, вход через SSH:\n'
  printf '   ssh -p %s -L %s:127.0.0.1:%s %s@%s\n   и открой в браузере  http://localhost:%s\n' "$PANEL_SSH_PORT" "$PANEL_PORT" "$PANEL_PORT" "$SSH_USER" "$PANEL_HOST" "$PANEL_PORT"
fi
printf '%s======================================================================%s\n' "$c_g" "$c_0"
