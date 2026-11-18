#!/usr/bin/env bash
# РОССИЙСКИЙ сервер: вход (то, к чему подключается клиент), разделение трафика, цепочка на зарубежный сервер, мини-панель.
# Запускается оркестратором vless-setup.sh; переменные приходят export-строками перед этим текстом.
# Переменные (RU_IP, RELAY_IP, S_SUB и т.д.) приходят строками export от мастера, файлы состояния читаются через source:
# shellcheck disable=SC2153,SC1090,SC1091
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
TAG=RU
@@INCLUDE lib/common.sh@@

check_relay_reachable() {
  local code
  code="$(curl -sk --max-time 25 --resolve "$RELAY_DOMAIN:${RELAY_PORT:-443}:$RELAY_IP" "https://$RELAY_DOMAIN:${RELAY_PORT:-443}/" -o /dev/null -w '%{http_code}' || true)"
  if [ "$code" != 200 ]; then
    die "зарубежный сервер ($RELAY_IP:${RELAY_PORT:-443}) не отвечает с этого сервера (код $code). Скорее всего, его IP уже заблокирован из России: поменяй IP у хостера и запусти скрипт заново."
  fi
}

install_xray_ru() {
  local b=/tmp/ru-bundle
  [ -s "$STATE_DIR/ru-bundle.tgz" ] || die "не найден $STATE_DIR/ru-bundle.tgz (его должен был передать оркестратор)"
  rm -rf "$b"; install -d "$b"
  tar -xzf "$STATE_DIR/ru-bundle.tgz" -C "$b"
  rm -rf /tmp/xray-unpack; install -d /tmp/xray-unpack
  unzip -oq "$b/xray.zip" -d /tmp/xray-unpack
  install -d -m 755 "$XDIR"
  install -m 755 /tmp/xray-unpack/xray "$XRAY"
  if [ -s "$b/geoip.dat" ] && [ -s "$b/geosite.dat" ]; then
    install -m 644 "$b/geoip.dat" "$b/geosite.dat" "$XDIR/"   # расширенные списки runetfreedom (ru-blocked и др.)
  else
    warn "списков runetfreedom в пакете нет — беру стандартные geoip/geosite из архива Xray"
    install -m 644 /tmp/xray-unpack/geoip.dat /tmp/xray-unpack/geosite.dat "$XDIR/"
  fi
  rm -rf "$b" /tmp/xray-unpack
  log "Установлен $(xver)"
}

gen_ru_config() { # $1 = target|dest (имя поля REALITY), $2 = набор правил: 1 полный, 2 без списков runetfreedom, 3 минимальный
  local tkey="$1" v="$2" rules ru_doms
  local D_FULL='"geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"'
  local D_MIN='"domain:ru", "domain:su", "domain:xn--p1ai"'
  if [ "$v" = 3 ]; then ru_doms="$D_MIN"; else ru_doms="$D_FULL"; fi
  local R_DNS='{ "type": "field", "port": "53", "outboundTag": "dns-out" },'
  local R_INSIDE='{ "type": "field", "domain": ["geosite:ru-available-only-inside"], "outboundTag": "direct-ru" },'
  local R_BLOCKED_D='{ "type": "field", "domain": ["geosite:ru-blocked"], "outboundTag": "to-relay" },'
  local R_RU_D="{ \"type\": \"field\", \"domain\": [$ru_doms], \"outboundTag\": \"direct-ru\" },"
  local R_PRIV='{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },'
  local R_BLOCKED_IP='{ "type": "field", "ip": ["geoip:ru-blocked"], "outboundTag": "to-relay" },'
  local R_RU_IP='{ "type": "field", "ip": ["geoip:ru"], "outboundTag": "direct-ru" },'
  local R_UDP443='{ "type": "field", "network": "udp", "port": "443", "outboundTag": "block" },'
  local R_LAST='{ "type": "field", "network": "tcp,udp", "outboundTag": "to-relay" }'
  case "$v" in
    1) rules="$R_DNS $R_INSIDE $R_BLOCKED_D $R_RU_D $R_PRIV $R_BLOCKED_IP $R_RU_IP $R_UDP443 $R_LAST" ;;
    *) rules="$R_DNS $R_RU_D $R_PRIV $R_RU_IP $R_UDP443 $R_LAST" ;;
  esac
  cat <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "dns": {
    "servers": [
      { "address": "localhost", "domains": [ $ru_doms ], "skipFallback": true },
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [{
    "tag": "from-router",
    "listen": "0.0.0.0",
    "port": ${RU_LISTEN_PORT:-443},
    "protocol": "vless",
    "settings": { "clients": [ { "id": "$RU_UUID" } ], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "$tkey": "127.0.0.1:$DECOY_PORT",
        "serverNames": [ "$RU_DOMAIN" ],
        "privateKey": "$RU_PRIV",
        "shortIds": [ "$RU_SID" ]
      },
      "xhttpSettings": { "path": "$RU_PATH", "mode": "auto" }
    },
    "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
  }],
  "outbounds": [
    { "tag": "block", "protocol": "blackhole" },
    {
      "tag": "to-relay",
      "protocol": "vless",
      "settings": { "vnext": [ { "address": "$RELAY_IP", "port": ${RELAY_PORT:-443}, "users": [ { "id": "$RELAY_UUID", "encryption": "none" } ] } ] },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$RELAY_DOMAIN",
          "fingerprint": "$FP",
          "publicKey": "$RELAY_PUB",
          "shortId": "$RELAY_SID"
        },
        "xhttpSettings": {
          "path": "$RELAY_PATH",
          "mode": "auto",
          "extra": { "xmux": { "maxConcurrency": "16-32", "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000" } }
        }
      }
    },
    { "tag": "direct-ru", "protocol": "freedom", "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } } },
    { "tag": "dns-out", "protocol": "dns" }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [ $rules ]
  }
}
EOF
}
apply_ru_config() {
  local tkey v tmp=/tmp/ru-config.json
  for tkey in target dest; do
    for v in 1 2 3; do
      gen_ru_config "$tkey" "$v" > "$tmp"
      if XRAY_LOCATION_ASSET="$XDIR" "$XRAY" run -test -config "$tmp" >/tmp/xray-test.log 2>&1; then
        install -m 640 -o root -g xray "$tmp" "$XDIR/config.json"
        if [ "$v" != 1 ]; then warn "применён упрощённый набор правил №$v (часть списков runetfreedom недоступна в этой сборке)"; fi
        log "конфиг принят (поле REALITY: $tkey, набор правил: $v)"
        return 0
      fi
    done
  done
  cat /tmp/xray-test.log
  die "Xray не принял конфиг (вывод выше)"
}

# Самопроверка: поднимаем временный клиент ПРЯМО НА ЭТОМ сервере и гоняем трафик по всей цепочке
selftest() {
  local cfg=/tmp/vless-selftest.json lg=/tmp/vless-selftest.log pid out ip warp i ok=0 got sp
  sp="$(pick_port 31080 31081 31082 41080)" || die "нет свободного порта для самопроверки"
  local px=(--socks5-hostname "127.0.0.1:$sp")
  cat > "$cfg" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": $sp, "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${RU_LISTEN_PORT:-443}, "users": [ { "id": "$RU_UUID", "encryption": "none" } ] } ] },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": { "serverName": "$RU_DOMAIN", "fingerprint": "$FP", "publicKey": "$RU_PUB", "shortId": "$RU_SID" },
      "xhttpSettings": { "path": "$RU_PATH", "mode": "auto" }
    }
  } ]
}
EOF
  XRAY_LOCATION_ASSET="$XDIR" "$XRAY" run -config "$cfg" >"$lg" 2>&1 &
  pid=$!
  sleep 3
  for i in 1 2 3; do
    out="$(curl -s --max-time 30 "${px[@]}" https://www.cloudflare.com/cdn-cgi/trace || true)"
    ip="$(printf '%s\n' "$out" | sed -n 's/^ip=//p')"
    warp="$(printf '%s\n' "$out" | sed -n 's/^warp=//p')"
    if [ -n "$ip" ]; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" != 1 ]; then
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    tail -n 20 "$lg" || true
    die "цепочка не заработала: через вход не удалось открыть зарубежный сайт. Смотри лог выше и: journalctl -u vless-xray -n 50"
  fi
  log "зарубежный сайт видит адрес: $ip (warp=${warp:-нет})"
  if [ "$ip" = "$RU_IP" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; die "зарубежный трафик выходит с IP российского сервера — на зарубежный сервер он не ушёл"; fi
  if [ "$EXIT_MODE" = warp ]; then
    if [ "$ip" = "$RELAY_IP" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; die "выход идёт с IP зарубежного сервера, а должен через WARP — проверь warp-cli на зарубежном сервере"; fi
    if [ "$warp" != on ] && [ "$warp" != plus ]; then warn "Cloudflare не подтвердил WARP (warp=${warp:-пусто}), но IP не совпадает ни с одним из серверов"; fi
  fi
  got="$(curl -s --max-time 25 -A curl "${px[@]}" https://2ip.ru 2>/dev/null | tr -d ' \r\n' || true)"
  if [ "$got" = "$RU_IP" ]; then log "российские сайты видят адрес RU-сервера: $got — как и задумано"; else warn "проверка российского выхода: ждал $RU_IP, получил «${got:0:40}» (2ip.ru мог быть недоступен) — не критично"; fi
  got="$(curl -s --max-time 90 -o /dev/null -w '%{size_download}' "${px[@]}" 'https://speed.cloudflare.com/__down?bytes=8000000' 2>/dev/null || true)"
  if [ "${got:-0}" -ge 7900000 ] 2>/dev/null; then log "тест объёма: через цепочку скачано $got байт — «заморозки» нет"; else warn "тест объёма: скачано ${got:-0} из 8000000 байт. Если так будет и в работе — возможна «заморозка» соединения между серверами (см. разборы ТСПУ)"; fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  rm -f "$cfg"
}

@@INCLUDE lib/panel-install.sh@@

main() {
  trap 'die "сбой на строке $LINENO: $BASH_COMMAND"' ERR
  : "${CONN_PORT:=443}" "${RELAY_PORT:=443}"
  RU_LISTEN_PORT="$CONN_PORT"; VLESS_PORT="$CONN_PORT"
  [ -s "$STATE_DIR/ru-bundle.tgz" ] || die "не найден $STATE_DIR/ru-bundle.tgz (его должен был передать оркестратор)"
  if command -v ss >/dev/null 2>&1; then ensure_ports_free; fi   # до установки пакетов: не трогаем сервер, если порты заняты чужим
  prep_base
  ensure_ports_free
  log "Проверяю, что зарубежный сервер доступен отсюда"
  check_relay_reachable
  open_firewall
  DOMAIN="$RU_DOMAIN"
  DECOY_PORT="$(decoy_port)"
  ACME_FWD="$(acme_forward_port)"
  if [ -n "$ACME_FWD" ]; then log "запросы на порт 80 для других доменов nginx будет пересылать в Caddy (127.0.0.1:$ACME_FWD)"; fi

  log "Жду, пока $RU_DOMAIN начнёт указывать на $RU_IP"
  wait_dns "$RU_DOMAIN" "$RU_IP" || die "DNS для $RU_DOMAIN так и не указал на $RU_IP (DNS этого сервера мог закешировать старый ответ — подожди 5–10 минут и запусти скрипт заново)."

  log "Сайт-заглушка и сертификат Let's Encrypt"
  install -d -m 755 "$ACME_DIR"
  write_decoy_site ru
  write_nginx_conf plain
  get_cert
  write_nginx_conf tls

  log "Xray"
  install_xray_ru
  load_or_make_keys ru
  RU_UUID="$K_UUID"; RU_PRIV="$K_PRIV"; RU_PUB="$K_PUB"; RU_SID="$K_SID"; RU_PATH="$K_PATH"
  create_xray_user_and_service
  apply_ru_config
  systemctl restart vless-xray
  sleep 3
  if ! systemctl is-active --quiet vless-xray; then journalctl -u vless-xray -n 40 --no-pager || true; die "xray не запустился (лог выше)"; fi

  log "Проверка: сайт-заглушка отвечает через порт $CONN_PORT"
  local code
  code="$(curl -sk --max-time 20 --resolve "$RU_DOMAIN:$CONN_PORT:127.0.0.1" "https://$RU_DOMAIN:$CONN_PORT/" -o /dev/null -w '%{http_code}' || true)"
  if [ "$code" != 200 ]; then die "через порт $CONN_PORT заглушка не отвечает (код $code). Смотри: journalctl -u vless-xray -n 50"; fi

  log "Самопроверка всей цепочки (российский вход → зарубежный сервер → выход)"
  selftest

  local link
  link="vless://${RU_UUID}@${RU_IP}:${CONN_PORT}?encryption=none&security=reality&sni=${RU_DOMAIN}&fp=${FP}&pbk=${RU_PUB}&sid=${RU_SID}&type=xhttp&path=${RU_PATH//\//%2F}&mode=auto#vless-2srv"
  printf '%s\n' "$link" > "$STATE_DIR/link.txt"
  rm -f "$STATE_DIR/ru-bundle.tgz"

  log "Мини-панель"
  PANEL_PORT=""
  SRV_IP="$RU_IP"; SRV_DOMAIN="$RU_DOMAIN"   # RELAY_IP и RELAY_DOMAIN уже заданы
  SCHEME_LABEL="Два сервера: российский вход → зарубежный"; LINK_TAG="vless-2srv"; ENV_FILE="ru.env"
  install_panel || warn "панель не установилась (на ссылку это не влияет)"

  printf '\n@@PANEL_PORT=%s\n@@LINK=%s\n' "$PANEL_PORT" "$link"
  log "Российский сервер готов"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
