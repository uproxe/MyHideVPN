# ===================== общие функции (одинаковые для обоих серверов) =====================
STATE_DIR="${STATE_DIR:-/root/.vless-setup}"
XDIR="${XDIR:-/opt/vless-xray}"
XRAY="$XDIR/xray"
DECOY_DIR="${DECOY_DIR:-/var/www/decoy}"
ACME_DIR="${ACME_DIR:-/var/www/acme}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
NGINX_CONF="${NGINX_CONF:-$NGINX_DIR/conf.d/vless-decoy.conf}"
LE_DIR="${LE_DIR:-/etc/letsencrypt}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
FORCE="${FORCE:-0}"
EXIT_MODE="${EXIT_MODE:-warp}"
FP="${FP:-firefox}"
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold -y"
VPN_RE='xray|x-ui|3x-ui|sing-box|hysteria|v2ray|trojan|ss-server|ssserver|marzban'

log()  { printf '\n\033[1;32m[%s] %s\033[0m\n' "$TAG" "$*"; }
warn() { printf '\033[1;33m[%s] ВНИМАНИЕ: %s\033[0m\n' "$TAG" "$*"; }
die()  { printf '\n\033[1;31m[%s] ОШИБКА: %s\033[0m\n' "$TAG" "$*" >&2; exit 1; }
dl()   { curl -fL -sS --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1"; }
xver() { XRAY_LOCATION_ASSET="$XDIR" "$XRAY" version 2>&1 | sed -n '1p'; }

# ---------- порты: ничего не ломаем, если на 80/443 уже что-то чужое ----------
port_info() { # $1=порт -> "имя|pid" процесса, который слушает tcp-порт (или пусто)
  ss -ltnp "sport = :$1" 2>/dev/null \
    | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1|\2/p' | head -n1 || true
}
port_busy() { ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN; }
pick_port() { # первый свободный порт из списка аргументов
  local p
  for p in "$@"; do
    if [ "$p" = "${VLESS_PORT:-443}" ] || [ "$p" = 80 ]; then continue; fi
    if ! port_busy "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}
is_our_xray() { # бинарник мог быть заменён при прошлом запуске — тогда в /proc он помечен «(deleted)»
  local e
  e="$(readlink -f "/proc/$1/exe" 2>/dev/null || true)"
  [ "${e% (deleted)}" = "$XRAY" ]
}
nginx_is_ours() { # в конфигах nginx нет ничего, кроме дефолтного сайта и нашего файла
  local extra
  extra="$(find "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-enabled" -mindepth 1 \( -type f -o -type l \) \
           ! -name default ! -name "$(basename "$NGINX_CONF")" 2>/dev/null | head -n1 || true)"
  [ -z "$extra" ]
}
stop_old_vpn() {
  local u
  for u in x-ui 3x-ui xray sing-box hysteria-server hysteria v2ray marzban shadowsocks-libev; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      log "остановлен и отключён сервис $u"
    fi
  done
  sleep 2
}
ensure_ports_free() {
  local p info name pid
  for p in 80 "${VLESS_PORT:-443}"; do
    info="$(port_info "$p")"
    if [ -z "$info" ]; then continue; fi
    name="${info%%|*}"; pid="${info##*|}"
    if is_our_xray "$pid"; then continue; fi
    if [ "$p" = 80 ] && [ "$name" = nginx ] && nginx_is_ours; then continue; fi
    if [ "$p" = 80 ] && [ "$name" = caddy ]; then move_caddy_off_80 "$pid"; continue; fi
    if printf '%s' "$name" | grep -Eq "$VPN_RE"; then
      if [ "$FORCE" = 1 ]; then
        warn "порт $p занят «$name» (похоже на старый VPN) — останавливаю, раз указан FORCE=1"
        stop_old_vpn
        if [ -n "$(port_info "$p")" ]; then die "порт $p всё ещё занят после остановки старых сервисов — освободи его вручную"; fi
      else
        die "порт $p занят процессом «$name» — похоже на старый VPN. Если его можно остановить, запусти скрипт заново так:  FORCE=1 bash vless-setup.sh"
      fi
    else
      die "порт $p занят процессом «$name». Чтобы не сломать другие сервисы, скрипт ничего не трогает. Освободи порт или возьми чистый сервер."
    fi
  done
}

# ---------- Caddy на порту 80 (например, ваш сайт или веб-приложение) ----------
# Caddy держит 80 только ради проверок сертификата Let's Encrypt и редиректа http→https.
# Переносим его HTTP на свободный порт (8080…), а nginx на 80 пересылает ему всё, что пришло не для нашего домена.
# Сайты Caddy (например, на 8443) продолжают работать как раньше, сертификаты продлеваются.
caddy_config_path() { # $1 = pid caddy -> путь к его конфигу
  local p=""
  if [ -r "/proc/$1/cmdline" ]; then
    p="$(tr '\0' '\n' < "/proc/$1/cmdline" | awk 'f{print; exit} $0=="--config"{f=1}' || true)"
  fi
  if [ -z "$p" ]; then p=/etc/caddy/Caddyfile; fi
  printf '%s' "$p"
}
caddy_http_port_in() { # $1 = Caddyfile -> значение http_port (или пусто)
  grep -E '^[[:space:]]*http_port[[:space:]]+[0-9]+' "$1" 2>/dev/null | awk '{print $2; exit}' || true
}
caddy_unit() { # $1 = pid -> имя systemd-юнита
  local u=""
  if [ -r "/proc/$1/cgroup" ]; then u="$(sed -n 's#.*/\([^/]*\.service\)$#\1#p' "/proc/$1/cgroup" | head -n1 || true)"; fi
  printf '%s' "${u:-caddy.service}"
}
caddy_ports() { # TCP-порты, которые слушает caddy, через пробел
  ss -ltnp 2>/dev/null | awk 'index($0, "((\"caddy\",") > 0 { n = split($4, a, ":"); print a[n] }' | sort -un | tr '\n' ' ' || true
}
caddy_check_moved() { # $1 = новый порт, $2 = порты до изменения -> 0, если всё как надо
  local after p
  systemctl is-active --quiet "$CADDY_UNIT" || return 1
  [ -z "$(port_info 80)" ] || return 1
  after=" $(caddy_ports) "
  case "$after" in *" $1 "*) ;; *) return 1 ;; esac
  for p in $2; do
    if [ "$p" = 80 ]; then continue; fi
    case "$after" in *" $p "*) ;; *) return 1 ;; esac
  done
  return 0
}
move_caddy_off_80() { # $1 = pid процесса caddy, который держит порт 80
  local pid="$1" cf bak first port before i ok=0
  local note='# vless-setup: порт 80 теперь у nginx, он пересылает сюда проверки сертификатов (http_port не убирать)'
  command -v caddy >/dev/null 2>&1 || die "порт 80 занят Caddy, но команды caddy нет — освободи порт 80 вручную"
  cf="$(caddy_config_path "$pid")"
  CADDY_UNIT="$(caddy_unit "$pid")"
  case "$cf" in *.json) die "Caddy работает с JSON-конфигом ($cf) — сам поменять не возьмусь. Освободи порт 80 вручную." ;; esac
  [ -f "$cf" ] || die "не нашёл конфиг Caddy: $cf"
  if [ -n "$(caddy_http_port_in "$cf")" ]; then
    die "в $cf уже задан http_port, но Caddy всё равно держит порт 80 (видимо, там сайт явно на :80) — поправь Caddyfile вручную"
  fi
  port="$(pick_port 8080 8081 18080 28080)" || die "нет свободного порта для HTTP Caddy"
  before="$(caddy_ports)"
  bak="$cf.bak-vless-$(date +%Y%m%d-%H%M%S)"
  cp -a "$cf" "$bak"
  first="$(grep -vE '^[[:space:]]*(#|$)' "$bak" | head -n1 | sed 's/[[:space:]]#.*$//' | tr -d '[:space:]' || true)"
  if [ "$first" = "{" ]; then   # глобальный блок уже есть — дописываем в него
    awk -v p="$port" -v n="$note" '!d && $0 ~ /^[ \t]*[{][ \t]*(#.*)?$/ { print; print "\t" n; print "\thttp_port " p; d = 1; next } { print }' "$bak" > "$cf"
  elif [ "${first#\{}" != "$first" ]; then
    die "глобальный блок в $cf записан в одну строку — допиши в него вручную «http_port $port» и запусти скрипт снова"
  else                          # глобального блока нет — добавляем его в начало
    { printf '{\n\t%s\n\thttp_port %s\n}\n\n' "$note" "$port"; cat "$bak"; } > "$cf"
  fi
  chown --reference="$bak" "$cf" 2>/dev/null || true
  chmod --reference="$bak" "$cf" 2>/dev/null || true
  if ! caddy adapt --adapter caddyfile --config "$cf" >/tmp/caddy-adapt.log 2>&1; then
    cp -a "$bak" "$cf"
    tail -n 15 /tmp/caddy-adapt.log || true
    die "Caddy не принял изменённый конфиг — вернул всё как было"
  fi
  log "Порт 80 занят Caddy: переношу его HTTP на $port, сайты Caddy продолжат работать (копия конфига: $bak)"
  systemctl restart "$CADDY_UNIT" || true
  for i in $(seq 1 15); do
    if caddy_check_moved "$port" "$before"; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" != 1 ]; then
    local now
    now="$(caddy_ports)"
    cp -a "$bak" "$cf"
    systemctl restart "$CADDY_UNIT" || true
    die "после изменения Caddy заработал не так, как раньше (порты были: ${before}стали: ${now:-никаких}) — вернул старый конфиг, Caddy работает как прежде. Освободи порт 80 вручную."
  fi
  install -d -m 700 "$STATE_DIR"
  printf '%s' "$port" > "$STATE_DIR/caddy_http_port"
  log "Caddy работает (порты: $(caddy_ports)), порт 80 свободен"
}
acme_forward_port() { # порт HTTP Caddy, куда nginx пересылает запросы на 80 для чужих доменов (пусто — пересылать некуда)
  local p="" pid
  if [ -s "$STATE_DIR/caddy_http_port" ]; then p="$(cat "$STATE_DIR/caddy_http_port")"; fi
  if [ -z "$p" ]; then
    pid="$(ss -ltnp 2>/dev/null | sed -n 's/.*users:(("caddy",pid=\([0-9]*\).*/\1/p' | head -n1 || true)"
    if [ -n "$pid" ]; then p="$(caddy_http_port_in "$(caddy_config_path "$pid")")"; fi
  fi
  if [ -n "$p" ] && [ "$(port_info "$p" | cut -d'|' -f1)" = caddy ]; then printf '%s' "$p"; fi
  return 0
}

# ---------- DNS ----------
resolve4() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true; }
wait_dns() { # $1=домен $2=ожидаемый IP (ждём до ~3,5 минут)
  local i
  for i in $(seq 1 42); do
    if [ "$(resolve4 "$1")" = "$2" ]; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------- базовая подготовка (голый Debian: ставим вообще всё, что нужно) ----------
prep_base() {
  . /etc/os-release
  if [ "$(id -u)" != 0 ]; then die "нужны права root"; fi
  case "${ID:-}" in debian|ubuntu) ;; *) die "нужен Debian или Ubuntu (сейчас: ${ID:-неизвестно})" ;; esac
  command -v systemctl >/dev/null 2>&1 || die "нужен systemd"
  install -d -m 700 "$STATE_DIR"
  log "Ставлю зависимости (apt)"
  $APT update >/dev/null || warn "apt update вернул ошибку — продолжаю"
  $APT install --no-install-recommends curl ca-certificates iproute2 procps gnupg unzip openssl \
       nginx certbot python3 tar gzip sed gawk grep coreutils findutils libc-bin >/tmp/apt-install.log 2>&1 \
    || { tail -n 20 /tmp/apt-install.log; die "apt не смог установить пакеты (лог выше)"; }
}
open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow "${VLESS_PORT:-443}/tcp" >/dev/null
    log "ufw активен — порты 80 и ${VLESS_PORT:-443} открыты"
  fi
}

# ---------- сайт-заглушка ----------
# На домене должен жить обычный сайт. Код проекта публичный, поэтому заглушка у каждой установки своя:
# название, темы, тексты, цвета и шрифт выбираются случайно. Если в $DECOY_DIR уже лежит index.html
# (например, свой сайт), скрипт его не трогает.
pick() { local n=$#; [ "$n" -gt 0 ] || return 0; local i=$(( RANDOM % n + 1 )); printf '%s' "${!i}"; }
write_decoy_site() { # $1 = ru|en
  local d="$DECOY_DIR" lang="$1" t intro about h_home h_notes h_about filler stamp color font i
  local -a posts=() pool=()
  install -d -m 755 "$d"
  if [ -s "$d/index.html" ]; then log "сайт-заглушка уже есть в $d — оставляю как есть"; return 0; fi
  if [ "$lang" = ru ]; then
    h_home="Главная"; h_notes="Записи"; h_about="Об авторе"
    t="$(pick "Записки на полях" "Тихий угол" "Заметки по выходным" "Дневник наблюдений" "Медленное чтение" "Неспешные заметки" "Между делом" "Вечерние записи")"
    intro="$(pick "Небольшой личный блог. Пишу нерегулярно — когда есть что рассказать." \
                  "Здесь собраны заметки о том, что попадается на глаза: книги, поездки, мелкие домашние дела." \
                  "Личные записи без расписания и без рекламы. Просто чтобы не забыть." \
                  "Блог для себя и для тех, кто случайно сюда зашёл.")"
    pool=("Второй год с помидорами: что получилось" "Три недели с одной книгой" "Осенняя дорога: что взять с собой" \
          "Как я перестал покупать лишнее" "Заметки о старом фотоаппарате" "Хлеб на закваске: попытка номер четыре" \
          "Короткий поход выходного дня" "Чем пахнет март" "Пять фильмов для дождливого вечера" "Ремонт велосипеда своими руками" \
          "Почему я снова пишу от руки" "Список дел, который сработал" "Летние заготовки: итоги" "Зима, чай и настольные игры")
    filler="$(pick "Короткая запись для себя: черновые мысли и план на ближайшее время. Подробности добавлю позже." \
                   "Пока только заметка-напоминание. Вернусь к теме, когда наберётся материал." \
                   "Несколько мыслей по горячим следам, без претензии на полноту.")"
    about="$(pick "Живу в небольшом городе, люблю читать и гулять. Блог веду для себя, поэтому комментариев здесь нет." \
                  "Обычный человек с обычной работой. Здесь — то, что не помещается в голове." \
                  "Пишу о простых вещах. Контактов не оставляю — это просто дневник.")"
  else
    h_home="Home"; h_notes="Posts"; h_about="About"
    t="$(pick "Field Notes" "Quiet Corner" "Weekend Notes" "Slow Reading" "Margins" "Small Things" "Evening Log" "Notes to Self")"
    intro="$(pick "A small personal blog. Posts appear whenever there is something worth writing down." \
                  "Notes about books, short trips and small things around the house." \
                  "Personal notes with no schedule and no ads. Mostly so I don't forget." \
                  "A blog for myself and for anyone who happens to wander in.")"
    pool=("Second year with tomatoes" "Three weeks with a single book" "Autumn road: what to pack" "How I stopped buying things" \
          "Notes on an old film camera" "Sourdough, attempt number four" "A short weekend hike" "What March smells like" \
          "Five films for a rainy evening" "Fixing a bicycle at home" "Why I write by hand again" "A to-do list that actually worked" \
          "Summer preserves: results" "Winter, tea and board games")
    filler="$(pick "A short note to myself: rough thoughts and a plan for the near future. More details later." \
                   "Just a reminder for now. I will come back to this when there is more to say." \
                   "A few thoughts while they are fresh, nothing more.")"
    about="$(pick "I live in a small town and like reading and walking. The blog is for my own use, so there are no comments." \
                  "An ordinary person with an ordinary job. This is where the overflow goes." \
                  "I write about simple things. No contact details — it is just a journal.")"
  fi
  for i in 1 2 3 4 5; do posts+=("${pool[$(( RANDOM % ${#pool[@]} ))]}"); done
  # уникальные записи, от 3 до 5 штук
  mapfile -t posts < <(printf '%s\n' "${posts[@]}" | awk '!s[$0]++' | head -n $(( RANDOM % 3 + 3 )))
  color="$(pick "#357" "#2d6a4f" "#7b2d26" "#4a4e69" "#8a5a00" "#1d4e89" "#5c3c70" "#3a6b35")"
  font="$(pick "Georgia,serif" "'Palatino Linotype',Palatino,serif" "Charter,'Bitstream Charter',serif" "system-ui,sans-serif" "'Iowan Old Style',serif" "Verdana,sans-serif")"
  stamp="$(( $(date +%Y) - RANDOM % 3 ))"
  page() { # $1 файл, $2 заголовок страницы, $3 тело
    cat > "$d/$1" <<PAGE
<!doctype html>
<html lang="$lang">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$2 — $t</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header>
<h1>$t</h1>
<nav><a href="/">$h_home</a> · <a href="/posts.html">$h_notes</a> · <a href="/about.html">$h_about</a></nav>
</header>
<main>
$3
</main>
<footer>© $stamp–$(date +%Y)</footer>
</body>
</html>
PAGE
  }
  local list="" arts="" p
  for p in "${posts[@]}"; do list="$list<li>$p</li>"; arts="$arts<article><h3>$p</h3><p>$filler</p></article>"; done
  page index.html "$h_home" "<p>$intro</p><h2>$h_notes</h2><ul>$list</ul>"
  page posts.html "$h_notes" "<h2>$h_notes</h2>$arts"
  page about.html "$h_about" "<h2>$h_about</h2><p>$about</p>"
  cat > "$d/style.css" <<CSS
body{font-family:$font;max-width:$(( RANDOM % 8 + 38 ))rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#222;background:#fbfbf9}
header{border-bottom:1px solid #ddd;margin-bottom:1.5rem}
h1{margin:.2em 0;color:$color}
nav a{color:$color;text-decoration:none}
footer{margin-top:3rem;color:#888;font-size:.9rem}
CSS
  printf 'User-agent: *\nAllow: /\n' > "$d/robots.txt"
}

# ---------- nginx + сертификат ----------
decoy_port() { # локальный порт сайта-заглушки: выбирается один раз и запоминается
  local p
  if [ -s "$STATE_DIR/decoy_port" ]; then
    p="$(cat "$STATE_DIR/decoy_port")"
    if [ "$p" != "${VLESS_PORT:-443}" ]; then printf '%s' "$p"; return 0; fi
  fi
  p="$(pick_port 8443 9443 18443 28443 38443)" || die "не нашёл свободный локальный порт для сайта-заглушки"
  printf '%s' "$p" > "$STATE_DIR/decoy_port"
  printf '%s' "$p"
}
nginx_conf_body() { # $1 = plain|tls  $2 = new|old (синтаксис http2)
  local l2 h2="" dflt=" default_server"
  if [ "$2" = new ]; then l2="listen 127.0.0.1:$DECOY_PORT ssl;"; h2="http2 on;"; else l2="listen 127.0.0.1:$DECOY_PORT ssl http2;"; fi
  if [ -n "${ACME_FWD:-}" ]; then
    dflt=""
    cat <<EOF
# всё, что пришло на порт 80 не для $DOMAIN (сайты Caddy и их проверки сертификатов), — в Caddy, как было раньше
server {
    listen 80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$ACME_FWD;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}

EOF
  fi
  cat <<EOF
server {
    listen 80$dflt;
    server_name $DOMAIN;
    root $ACME_DIR;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  if [ "$1" = tls ]; then
    cat <<EOF

server {
    $l2
    $h2
    server_name $DOMAIN;
    charset utf-8;
    ssl_certificate     $LE_DIR/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key $LE_DIR/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    root $DECOY_DIR;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  fi
}
write_nginx_conf() { # $1 = plain|tls ; домен берётся из $DOMAIN, порт из $DECOY_PORT
  local syn ok=0
  install -d -m 755 "$(dirname "$NGINX_CONF")"
  rm -f "$NGINX_DIR/sites-enabled/default"
  for syn in new old; do   # nginx >= 1.25: «http2 on;», старее: «listen … http2»
    nginx_conf_body "$1" "$syn" > "$NGINX_CONF"
    if nginx -t >/tmp/nginx-test.log 2>&1; then ok=1; break; fi
  done
  if [ "$ok" != 1 ]; then cat /tmp/nginx-test.log; die "nginx: ошибка в конфигурации"; fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || { journalctl -u nginx -n 20 --no-pager || true; die "nginx не запустился"; }
}
get_cert() {
  local i
  if [ -s "$LE_DIR/live/$DOMAIN/fullchain.pem" ]; then return 0; fi
  install -d -m 755 "$LE_DIR/renewal-hooks/deploy"
  printf '#!/bin/sh\nsystemctl reload nginx\n' > "$LE_DIR/renewal-hooks/deploy/reload-nginx.sh"
  chmod +x "$LE_DIR/renewal-hooks/deploy/reload-nginx.sh"
  for i in 1 2 3; do
    if certbot certonly --webroot -w "$ACME_DIR" -d "$DOMAIN" --non-interactive --agree-tos \
         --register-unsafely-without-email >/tmp/certbot.log 2>&1; then
      return 0
    fi
    warn "certbot: попытка $i из 3 не удалась, жду 30 секунд…"
    sleep 30
  done
  tail -n 25 /tmp/certbot.log || true
  die "не удалось получить сертификат Let's Encrypt для $DOMAIN. Если в логе выше «too many certificates» — это недельный лимит Let's Encrypt на один и тот же домен: возьми другой поддомен или подожди. Иначе проверь, что порт 80 открыт снаружи (в панели хостера и в файрволе) и что DNS указывает на этот сервер."
}

# ---------- Xray: пользователь, сервис, ключи ----------
create_xray_user_and_service() {
  getent group xray >/dev/null 2>&1 || groupadd --system xray
  id xray >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin -g xray xray
  cat > "$UNIT_DIR/vless-xray.service" <<EOF
[Unit]
Description=Xray (vless-setup)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=$XDIR
ExecStart=$XRAY run -config $XDIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vless-xray >/dev/null 2>&1
}
make_keys() { # -> K_UUID K_PRIV K_PUB K_SID K_PATH
  local out
  out="$(XRAY_LOCATION_ASSET="$XDIR" "$XRAY" x25519 2>&1)" || die "xray x25519 не отработал: $out"
  K_PRIV="$(printf '%s\n' "$out" | awk -F': *' '/[Pp]rivate/{print $2; exit}' | tr -d ' \r')"
  K_PUB="$(printf '%s\n' "$out" | awk -F': *' '/[Pp]ublic|Password/{print $2; exit}' | tr -d ' \r')"
  printf '%s' "$K_PRIV" | grep -Eq '^[A-Za-z0-9_-]{43}$' || die "не смог разобрать приватный ключ из вывода xray x25519: $out"
  printf '%s' "$K_PUB"  | grep -Eq '^[A-Za-z0-9_-]{43}$' || die "не смог разобрать публичный ключ из вывода xray x25519: $out"
  K_UUID="$(cat /proc/sys/kernel/random/uuid)"
  K_SID="$(openssl rand -hex 8)"
  K_PATH="/$(openssl rand -hex 6)"
}
save_state() { # $1 = имя файла состояния
  umask 077
  cat > "$STATE_DIR/$1.env" <<EOF
K_UUID=$K_UUID
K_PRIV=$K_PRIV
K_PUB=$K_PUB
K_SID=$K_SID
K_PATH=$K_PATH
EOF
  umask 022
}
load_or_make_keys() { # $1 = имя файла состояния (при повторном запуске ключи сохраняются)
  if [ -s "$STATE_DIR/$1.env" ]; then
    . "$STATE_DIR/$1.env"
  else
    make_keys
    save_state "$1"
  fi
}
