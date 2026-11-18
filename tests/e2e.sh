#!/usr/bin/env bash
# Сквозные тесты мастера на имитации серверов.
#
# Настоящие серверы не нужны: ssh подменяется заглушкой, которая выполняет «удалённые» команды локально,
# а системные программы (apt-get, systemctl, nginx, certbot, warp-cli, curl, ss…) — заглушками,
# которые ничего не меняют в системе. Xray подменяется фальшивым бинарником.
#
# Нужен root (скрипты создают системного пользователя xray и ставят файлы с владельцем root:xray),
# поэтому запускайте в одноразовом окружении (контейнер, CI):   sudo bash tests/e2e.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/dist/vless-setup.sh"
[ -f "$SETUP" ] || { echo "сначала соберите: python3 tools/build.py" >&2; exit 2; }
if [ "$(id -u)" != 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo -E bash "$0" "$@"; fi
  echo "нужен root" >&2; exit 2
fi
for t in python3 unzip openssl awk sha256sum; do command -v "$t" >/dev/null 2>&1 || { echo "нет команды $t" >&2; exit 2; }; done

V="$(mktemp -d "${TMPDIR:-/tmp}/vless-e2e.XXXXXX")"
trap 'rm -rf "$V"' EXIT
mkdir -p "$V/bin" "$V/zip"

TOKEN="aaaaaaaa-1111-2222-3333-444455556666"
RU=198.51.100.20; RELAY=203.0.113.30; ONE=203.0.113.10; ONE_RU=198.51.100.7
printf 'ru-test.duckdns.org %s\nrelay-test.duckdns.org %s\nvps-test.duckdns.org %s\nvpsru-test.duckdns.org %s\n' \
  "$RU" "$RELAY" "$ONE" "$ONE_RU" > "$V/dns"

# ---------- фальшивый xray ----------
cat > "$V/zip/xray" <<'EOF'
#!/usr/bin/env bash
rnd43() { head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }
case "${1:-}" in
  version) echo "Xray 99.0.0 (fake)"; exit 0 ;;
  x25519) printf 'PrivateKey: %s\nPassword (PublicKey): %s\nHash32: %s\n' "$(rnd43)" "$(rnd43)" "$(rnd43)"; exit 0 ;;
  run) shift
       if [ "${1:-}" = "-test" ]; then python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$3" || exit 1; echo "Configuration OK."; exit 0; fi
       exec sleep 600 ;;
esac
exit 0
EOF
chmod +x "$V/zip/xray"
head -c 200000 /dev/urandom > "$V/zip/geoip.dat"; cp "$V/zip/geoip.dat" "$V/zip/geosite.dat"
python3 - "$V" <<'EOF'
import sys, zipfile, os
v = sys.argv[1]
with zipfile.ZipFile(os.path.join(v, "xray-test.zip"), "w") as z:
    for n in ("xray", "geoip.dat", "geosite.dat"):
        info = zipfile.ZipInfo(n); info.external_attr = 0o755 << 16
        z.writestr(info, open(os.path.join(v, "zip", n), "rb").read())
EOF

# ---------- заглушки (в тексте __V__ заменяется на каталог стенда) ----------
stub() { sed "s#__V__#$V#g" > "$V/bin/$1"; chmod +x "$V/bin/$1"; }
for n in sleep journalctl ufw; do printf '#!/bin/sh\nexit 0\n' | stub "$n"; done
stub apt-get <<'EOF'
#!/usr/bin/env bash
echo "apt-get $* (${FAKE_HOST:-})" >> __V__/apt.log; exit 0
EOF
stub nginx <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
stub gpg <<'EOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done; cat > "${out:-/dev/null}"
EOF
stub certbot <<'EOF'
#!/usr/bin/env bash
dom=""; while [ $# -gt 0 ]; do [ "$1" = "-d" ] && dom="$2"; shift; done
mkdir -p "$LE_DIR/live/$dom"; echo c > "$LE_DIR/live/$dom/fullchain.pem"; echo k > "$LE_DIR/live/$dom/privkey.pem"
EOF
stub warp-cli <<'EOF'
#!/usr/bin/env bash
touch __V__/warp-up; exit 0
EOF
stub systemctl <<'EOF'
#!/usr/bin/env bash
echo "systemctl $* (${FAKE_HOST:-})" >> __V__/systemctl.log
case "$1" in
  cat) [ -n "${FAKE_UNIT:-}" ] && [ "$2" = "${FAKE_UNIT}" ] && [ ! -e "__V__/stopped-${FAKE_HOST:-x}" ] && exit 0; exit 1 ;;
  disable) touch "__V__/stopped-${FAKE_HOST:-x}"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
stub ss <<'EOF'
#!/usr/bin/env bash
# занятый порт берётся из FAKE_SS_<порт>, только на сервере FAKE_SS_HOST; после остановки старого сервиса порт свободен
port="${*: -1}"; port="${port##*:}"
if [ -n "${FAKE_SS_HOST:-}" ] && [ "${FAKE_SS_HOST}" != "${FAKE_HOST:-}" ]; then exit 0; fi
[ -e "__V__/stopped-${FAKE_HOST:-x}" ] && exit 0
var="FAKE_SS_$port"; line="${!var:-}"
[ -n "$line" ] && printf '%s\n' "$line"
exit 0
EOF
stub getent <<'EOF'
#!/usr/bin/env bash
if [ "$1" = ahostsv4 ]; then ip="$(awk -v d="$2" '$1==d{print $2}' __V__/dns)"; [ -n "$ip" ] && printf '%s STREAM %s\n' "$ip" "$2"; exit 0; fi
exec /usr/bin/getent "$@"
EOF
stub curl <<'EOF'
#!/usr/bin/env bash
args=("$@"); url=""; out=""; wfmt=""; proxy=""; i=0
while [ $i -lt ${#args[@]} ]; do a="${args[$i]}"
  case "$a" in -o) i=$((i+1)); out="${args[$i]}" ;; -w) i=$((i+1)); wfmt="${args[$i]}" ;; --resolve) i=$((i+1)) ;;
    --proxy|--socks5-hostname) i=$((i+1)); proxy="${args[$i]}" ;; --max-time|--retry|--retry-delay|--connect-timeout|-A) i=$((i+1)) ;;
    -*) ;; *) url="$a" ;; esac
  i=$((i+1)); done
body=""; code=200; size=0
case "$url" in
  *duckdns.org/update*) if [ "${FAKE_DUCK_KO:-0}" = 1 ]; then body=KO; else body=OK; fi ;;
  *Xray-linux-*.zip.dgst) body="SHA2-256= $(sha256sum __V__/xray-test.zip | awk '{print $1}')" ;;
  *Xray-linux-*.zip) cp __V__/xray-test.zip "$out"; exit 0 ;;
  *runetfreedom*) head -c 300000 /dev/urandom > "$out"; exit 0 ;;
  *pubkey.gpg) body=key ;;
  *dists/*) exit 0 ;;
  *cdn-cgi/trace) if [ -n "$proxy" ]; then [ -e __V__/warp-up ] || exit 7; body=$'fl=1\nip=104.28.1.1\nwarp=on'; fi ;;
  *2ip.ru*) body="${S_IP:-${RU_IP:-}}" ;;
  *speed.cloudflare.com*) size=8000000 ;;
  http://127.0.0.1:*) body="vless://panel-stub" ;;
esac
if [ -n "$out" ] && [ "$out" != /dev/null ]; then printf '%s' "$body" > "$out"; elif [ -z "$out" ]; then printf '%s' "$body"; [ -n "$body" ] && echo; fi
if [ -n "$wfmt" ]; then w="${wfmt//%\{http_code\}/$code}"; w="${w//%\{size_download\}/$size}"; printf '%s' "$w"; fi
exit 0
EOF
stub ssh <<'EOF'
#!/usr/bin/env bash
# фальшивый ssh: каждый «сервер» — свой каталог __V__/<ip>root, команда выполняется локально
host=""; cmd=(); skip=0; nf=0; sport=""
for a in "$@"; do
  if [ -n "$host" ]; then cmd+=("$a"); continue; fi
  if [ "$skip" = p ]; then sport="$a"; skip=0; continue; fi
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -O) exit 0 ;; -o) skip=1 ;; -p) skip=p ;; -Nf) nf=1 ;; -*) ;; *@*) host="${a#*@}" ;; *) ;; esac
done
echo "ssh $host:${sport:-?} nf=$nf" >> __V__/ssh.log
[ "$nf" = 1 ] && exit 0
r="__V__/${host}root"
export STATE_DIR=$r/state XDIR=$r/opt/vless-xray DECOY_DIR=$r/www/decoy ACME_DIR=$r/www/acme NGINX_DIR=$r/etc/nginx \
       LE_DIR=$r/etc/letsencrypt UNIT_DIR=$r/etc/systemd KEYRING_DIR=$r/keyrings APT_LIST_DIR=$r/aptlist PANEL_DIR=$r/panel
mkdir -p "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-enabled" "$UNIT_DIR" "$STATE_DIR"
export FAKE_HOST="$host"
c="${cmd[*]}"; c="${c//\/root\/.vless-setup/$STATE_DIR}"
case "$c" in *"/dev/tcp/"*) exit 0 ;; esac
exec bash -c "$c"
EOF

# ---------- запуск и проверки ----------
PASS=0; FAIL=0
fresh() { rm -rf "$V"/*root "$V"/stopped-* "$V/warp-up" "$V/ssh.log" "$V/systemctl.log" "$V/apt.log"; }
wiz() { # wiz <каталог> [ПЕРЕМЕННАЯ=значение…] — ответы мастеру на stdin; код возврата → RC
  local d="$V/run-$1"; shift
  mkdir -p "$d"
  (cd "$d" && env PATH="$V/bin:$PATH" VLESS_SETUP_STDIN=1 "$@" bash "$SETUP" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > out.log; exit "${PIPESTATUS[0]}")
  RC=$?
}
check() { # check <описание> <команда…>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"; fi
}
out() { cat "$V/run-$1/out.log"; }
link() { cat "$V/run-$1/vless-link.txt" 2>/dev/null; }
X443='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=777,fd=7))'

echo "1. Два сервера, ответы по умолчанию"
fresh; wiz two < <(printf '2\n%s\n\n%s\n\n%s\nru-test\nrelay-test\n\n' "$RU" "$RELAY" "$TOKEN")
check "мастер завершился успешно" [ "$RC" = 0 ]
check "ссылка ведёт на российский сервер, порт 443" grep -q "^vless://.*@$RU:443?.*security=reality.*type=xhttp" "$V/run-two/vless-link.txt"
check "зарубежный сервер настроен как ретранслятор" grep -q 'Зарубежный сервер готов' "$V/run-two/out.log"
check "на зарубежный заходили через российский" grep -q "ssh $RELAY:22 nf=1" "$V/ssh.log"
check "сайт-заглушка создан" test -s "$V/${RU}root/www/decoy/index.html"
L1="$(link two)"; D1="$(md5sum < "$V/${RU}root/www/decoy/index.html")"

echo "2. Повторный запуск с ответами из vless-setup.last (AUTO=1)"
rm -rf "$V"/stopped-*
wiz two AUTO=1 </dev/null
check "мастер завершился успешно" [ "$RC" = 0 ]
check "ссылка не изменилась" [ "$(link two)" = "$L1" ]
check "сайт-заглушка не перезаписан" [ "$(md5sum < "$V/${RU}root/www/decoy/index.html")" = "$D1" ]
check "токен запомнен" grep -q "SAVED_TOKEN=$TOKEN" "$V/run-two/vless-setup.last"
check "файл ответов закрыт от чужих (600)" [ "$(stat -c %a "$V/run-two/vless-setup.last")" = 600 ]

echo "3. Один зарубежный сервер, SSH-порт 2200"
fresh; wiz one < <(printf '1\n1\n%s\n2200\n%s\nvps-test\ny\n' "$ONE" "$TOKEN")
check "мастер завершился успешно" [ "$RC" = 0 ]
check "ssh шёл на порт 2200" grep -q "ssh $ONE:2200" "$V/ssh.log"
check "ssh ни разу не шёл на 22" bash -c "! grep -q ':22 ' '$V/ssh.log'"
check "ссылка на сервер, порт 443" grep -q "^vless://.*@$ONE:443?" "$V/run-one/vless-link.txt"
check "команда входа в панель с портом 2200" grep -q "ssh -p 2200 -L" "$V/run-one/out.log"

echo "4. Один российский сервер (через переменные)"
fresh; wiz oneru MODE=1 S_LOC=ru S_IP="$ONE_RU" S_SUB=vpsru-test DUCKDNS_TOKEN="$TOKEN" AUTO=1 </dev/null
check "мастер завершился успешно" [ "$RC" = 0 ]
check "заглушка на русском" grep -q 'lang="ru"' "$V/${ONE_RU}root/www/decoy/index.html"

echo "5. Один российский сервер без WARP — отказ до подключения"
fresh; wiz oneru-direct MODE=1 S_LOC=ru S_IP="$ONE_RU" S_SUB=vpsru-test DUCKDNS_TOKEN="$TOKEN" EXIT_MODE=direct AUTO=1 </dev/null
check "мастер отказал" [ "$RC" != 0 ]
check "на сервер не заходили" [ ! -s "$V/ssh.log" ]

echo "6. Старый xray на 443 — предложено остановить, ответ «да»"
fresh; wiz oldvpn FAKE_SS_HOST="$ONE" FAKE_UNIT=xray.service FAKE_SS_443="$X443" \
  < <(printf '1\n1\n%s\n\n%s\nvps-test\ny\ny\n' "$ONE" "$TOKEN")
check "мастер завершился успешно" [ "$RC" = 0 ]
check "старый xray остановлен" grep -q "disable --now xray ($ONE)" "$V/systemctl.log"

echo "7. На 443 чужая программа — выбран порт 2053"
fresh; wiz busy443 FAKE_SS_HOST="$ONE" FAKE_SS_443='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("apache2",pid=5,fd=4))' \
  < <(printf '1\n1\n%s\n\n%s\nvps-test\ny\ny\n2053\n' "$ONE" "$TOKEN")
check "мастер завершился успешно" [ "$RC" = 0 ]
check "ссылка на порт 2053" grep -q "@$ONE:2053?" "$V/run-busy443/vless-link.txt"

echo "8. Caddy на 80 — отказ от переноса"
fresh; wiz caddy FAKE_SS_HOST="$ONE" FAKE_SS_80='LISTEN 0 4096 *:80 *:* users:(("caddy",pid=2,fd=10))' \
  < <(printf '1\n1\n%s\n\n%s\nvps-test\ny\nn\n' "$ONE" "$TOKEN")
check "мастер остановился" [ "$RC" != 0 ]
check "на сервере ничего не ставили" [ ! -s "$V/apt.log" ]

echo "9. Ошибки ввода — мастер переспрашивает"
fresh; wiz typos < <(printf '1\n1\n999.1.1.1\n10.0.0.5\nn\n%s\nabc\n70000\n22\nmy-token\n%s\nМой_сайт\nvps-test\nДа\n' "$ONE" "$TOKEN")
check "мастер завершился успешно" [ "$RC" = 0 ]
check "неверный IP отклонён" grep -q 'не похоже на IPv4' "$V/run-typos/out.log"
check "внутренний IP распознан" grep -q 'внутренний адрес' "$V/run-typos/out.log"
check "неверный порт отклонён" grep -q 'число от 1 до 65535' "$V/run-typos/out.log"
check "неверный токен отклонён" grep -q 'Токен выглядит так' "$V/run-typos/out.log"

echo "10. Неизвестный поддомен DuckDNS — остановка до изменений"
fresh; wiz duckko FAKE_DUCK_KO=1 < <(printf '1\n1\n%s\n\n%s\nvps-test\ny\n' "$ONE" "$TOKEN")
check "мастер остановился" [ "$RC" != 0 ]
check "понятная причина" grep -q 'DuckDNS ответил KO' "$V/run-duckko/out.log"
check "на сервере ничего не ставили" [ ! -s "$V/apt.log" ]

echo
echo "Итог: $PASS прошло, $FAIL упало"
[ "$FAIL" = 0 ]
