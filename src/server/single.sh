#!/usr/bin/env bash
# ОДИН сервер: вход VLESS (REALITY + XHTTP), выход в интернет через Cloudflare WARP, рунет — напрямую с сервера.
# Запускается оркестратором vless-setup.sh; переменные приходят export-строками перед этим текстом.
# Переменные (RU_IP, RELAY_IP, S_SUB и т.д.) приходят строками export от мастера, файлы состояния читаются через source:
# shellcheck disable=SC2153,SC1090,SC1091
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
TAG=VPS
@@INCLUDE lib/common.sh@@
@@INCLUDE lib/warp.sh@@
@@INCLUDE lib/panel-install.sh@@

# ---------- DuckDNS ----------
duck_update() { # $1=поддомен $2=ip
  local r
  r="$(curl -fsS --max-time 25 "https://www.duckdns.org/update?domains=$1&token=${DUCKDNS_TOKEN}&ip=$2" 2>/dev/null || true)"
  [ "$r" = "OK" ]
}
setup_duck_keepalive() { # раз в 6 часов подтверждаем запись, чтобы DuckDNS не счёл домен заброшенным
  local f="$STATE_DIR/duck-keepalive.sh"
  umask 077
  printf '#!/bin/sh\ncurl -fsS --max-time 25 %s >/dev/null 2>&1\nexit 0\n' \
    "'https://www.duckdns.org/update?domains=$S_SUB&token=$DUCKDNS_TOKEN&ip=$S_IP'" > "$f"
  umask 022
  chmod 700 "$f"
  cat > "$UNIT_DIR/vless-duck.service" <<EOF
[Unit]
Description=DuckDNS keepalive (vless-setup)

[Service]
Type=oneshot
ExecStart=$f
EOF
  cat > "$UNIT_DIR/vless-duck.timer" <<EOF
[Unit]
Description=DuckDNS keepalive timer (vless-setup)

[Timer]
OnBootSec=3min
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vless-duck.timer >/dev/null 2>&1 || warn "не удалось включить таймер DuckDNS (не критично)"
}

# ---------- Xray (с запасными зеркалами: с российских серверов GitHub открывается не всегда) ----------
fetch_gh() { # $1 = URL на github.com, $2 = куда сохранить
  local m
  for m in "" "https://ghproxy.net/" "https://gh-proxy.com/"; do
    rm -f "$2"
    if dl "${m}$1" "$2" 2>/dev/null && [ -s "$2" ]; then return 0; fi
  done
  return 1
}
install_xray_single() {
  local base="https://github.com/XTLS/Xray-core/releases/latest/download" want got zip
  local geo="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
  case "$(uname -m)" in
    x86_64|amd64)  zip=Xray-linux-64.zip ;;
    aarch64|arm64) zip=Xray-linux-arm64-v8a.zip ;;
    *) die "архитектура $(uname -m) не поддерживается" ;;
  esac
  install -d -m 755 "$XDIR"
  log "Скачиваю Xray"
  fetch_gh "$base/$zip" "/tmp/$zip" || die "не удалось скачать Xray ни с GitHub, ни с зеркал. Если сервер в России — GitHub оттуда может быть закрыт: возьми схему из двух серверов (файлы пойдут через зарубежный) или один зарубежный сервер."
  if fetch_gh "$base/$zip.dgst" "/tmp/$zip.dgst"; then
    want="$(awk -F'= *' '/^SHA2-256/{print $2; exit}' "/tmp/$zip.dgst" | tr -d ' \r\n')"
    got="$(sha256sum "/tmp/$zip" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then die "контрольная сумма архива Xray не совпала — архив повреждён или подменён"; fi
  else
    warn "не удалось скачать контрольную сумму Xray — проверка целостности пропущена"
  fi
  rm -rf /tmp/xray-unpack; install -d /tmp/xray-unpack
  unzip -oq "/tmp/$zip" -d /tmp/xray-unpack
  install -m 755 /tmp/xray-unpack/xray "$XRAY"
  # расширенные списки runetfreedom (ru-blocked и др.) — желательны, но не обязательны
  if fetch_gh "$geo/geoip.dat" /tmp/rf-geoip.dat && fetch_gh "$geo/geosite.dat" /tmp/rf-geosite.dat \
     && [ "$(wc -c < /tmp/rf-geoip.dat)" -gt 100000 ] && [ "$(wc -c < /tmp/rf-geosite.dat)" -gt 100000 ]; then
    install -m 644 /tmp/rf-geoip.dat "$XDIR/geoip.dat"
    install -m 644 /tmp/rf-geosite.dat "$XDIR/geosite.dat"
    log "списки runetfreedom скачаны"
  else
    warn "списки runetfreedom не скачались — беру стандартные из архива Xray (правила будут проще)"
    install -m 644 /tmp/xray-unpack/geoip.dat /tmp/xray-unpack/geosite.dat "$XDIR/"
  fi
  rm -rf /tmp/xray-unpack /tmp/rf-geoip.dat /tmp/rf-geosite.dat
  log "Установлен $(xver)"
}

gen_single_config() { # $1 = target|dest (имя поля REALITY), $2 = набор правил: 1 полный, 2 без списков runetfreedom, 3 минимальный
  local tkey="$1" v="$2" rules ru_doms exit_ob
  local D_FULL='"geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"'
  local D_MIN='"domain:ru", "domain:su", "domain:xn--p1ai"'
  if [ "$v" = 3 ]; then ru_doms="$D_MIN"; else ru_doms="$D_FULL"; fi
  if [ "$EXIT_MODE" = direct ]; then
    exit_ob='{ "tag": "exit", "protocol": "freedom", "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } } }'
  else
    exit_ob='{ "tag": "exit", "protocol": "socks", "settings": { "servers": [ { "address": "127.0.0.1", "port": 40000 } ] } }'
  fi
  local R_DNS='{ "type": "field", "port": "53", "outboundTag": "dns-out" },'
  local R_INSIDE='{ "type": "field", "domain": ["geosite:ru-available-only-inside"], "outboundTag": "direct-ru" },'
  local R_BLOCKED_D='{ "type": "field", "domain": ["geosite:ru-blocked"], "outboundTag": "exit" },'
  local R_RU_D="{ \"type\": \"field\", \"domain\": [$ru_doms], \"outboundTag\": \"direct-ru\" },"
  local R_PRIV='{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },'
  local R_BLOCKED_IP='{ "type": "field", "ip": ["geoip:ru-blocked"], "outboundTag": "exit" },'
  local R_RU_IP='{ "type": "field", "ip": ["geoip:ru"], "outboundTag": "direct-ru" },'
  local R_UDP443='{ "type": "field", "network": "udp", "port": "443", "outboundTag": "block" },'
  local R_LAST='{ "type": "field", "network": "tcp,udp", "outboundTag": "exit" }'
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
    "tag": "from-client",
    "listen": "0.0.0.0",
    "port": $CONN_PORT,
    "protocol": "vless",
    "settings": { "clients": [ { "id": "$S_UUID" } ], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "$tkey": "127.0.0.1:$DECOY_PORT",
        "serverNames": [ "$S_DOMAIN" ],
        "privateKey": "$S_PRIV",
        "shortIds": [ "$S_SID" ]
      },
      "xhttpSettings": { "path": "$S_PATH", "mode": "auto" }
    },
    "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
  }],
  "outbounds": [
    { "tag": "block", "protocol": "blackhole" },
    $exit_ob,
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
apply_single_config() {
  local tkey v tmp=/tmp/single-config.json
  for tkey in target dest; do
    for v in 1 2 3; do
      gen_single_config "$tkey" "$v" > "$tmp"
      if XRAY_LOCATION_ASSET="$XDIR" "$XRAY" run -test -config "$tmp" >/tmp/xray-test.log 2>&1; then
        install -m 640 -o root -g xray "$tmp" "$XDIR/config.json"
        if [ "$v" != 1 ]; then warn "применён упрощённый набор правил №$v (часть списков runetfreedom недоступна)"; fi
        log "конфиг принят (поле REALITY: $tkey, набор правил: $v)"
        return 0
      fi
    done
  done
  cat /tmp/xray-test.log
  die "Xray не принял конфиг (вывод выше)"
}

# Самопроверка: временный клиент прямо на этом сервере, трафик через настоящий вход
selftest_single() {
  local cfg=/tmp/vless-selftest.json lg=/tmp/vless-selftest.log pid out ip warp i ok=0 got sp
  sp="$(pick_port 31080 31081 31082 41080)" || die "нет свободного порта для самопроверки"
  local px=(--socks5-hostname "127.0.0.1:$sp")
  cat > "$cfg" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": $sp, "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": $CONN_PORT, "users": [ { "id": "$S_UUID", "encryption": "none" } ] } ] },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": { "serverName": "$S_DOMAIN", "fingerprint": "$FP", "publicKey": "$S_PUB", "shortId": "$S_SID" },
      "xhttpSettings": { "path": "$S_PATH", "mode": "auto" }
    }
  } ]
}
EOF
  XRAY_LOCATION_ASSET="$XDIR" "$XRAY" run -config "$cfg" >"$lg" 2>&1 &
  pid=$!
  sleep 3
  stop_client() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  for i in 1 2 3; do
    out="$(curl -s --max-time 30 "${px[@]}" https://www.cloudflare.com/cdn-cgi/trace || true)"
    ip="$(printf '%s\n' "$out" | sed -n 's/^ip=//p')"
    warp="$(printf '%s\n' "$out" | sed -n 's/^warp=//p')"
    if [ -n "$ip" ]; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" != 1 ]; then
    stop_client; tail -n 20 "$lg" || true
    die "через VPN не открылся зарубежный сайт. Смотри лог выше и: journalctl -u vless-xray -n 50"
  fi
  log "зарубежные сайты видят адрес: $ip (warp=${warp:-нет})"
  if [ "$EXIT_MODE" = warp ]; then
    if [ "$ip" = "$S_IP" ]; then stop_client; die "выход идёт с IP самого сервера, а должен через WARP — проверь: warp-cli status"; fi
    if [ "$warp" != on ] && [ "$warp" != plus ]; then warn "Cloudflare не подтвердил WARP (warp=${warp:-пусто}), но адрес выхода отличается от адреса сервера"; fi
  else
    log "режим direct: выход с IP сервера, как и задумано"
  fi
  got="$(curl -s --max-time 25 -A curl "${px[@]}" https://2ip.ru 2>/dev/null | tr -d ' \r\n' || true)"
  if [ "$got" = "$S_IP" ]; then log "российские сайты видят адрес сервера: $got — как и задумано"; else warn "проверка рунета: ждал $S_IP, получил «${got:0:40}» (2ip.ru мог быть недоступен) — не критично"; fi
  got="$(curl -s --max-time 90 -o /dev/null -w '%{size_download}' "${px[@]}" 'https://speed.cloudflare.com/__down?bytes=8000000' 2>/dev/null || true)"
  if [ "${got:-0}" -ge 7900000 ] 2>/dev/null; then log "тест объёма: скачано $got байт — соединение не обрывается"; else warn "тест объёма: скачано ${got:-0} из 8000000 байт. Если так же будет в работе — соединение где-то обрывается"; fi
  stop_client
  rm -f "$cfg"
}

main() {
  trap 'die "сбой на строке $LINENO: $BASH_COMMAND"' ERR
  : "${CONN_PORT:=443}" "${S_DUCK:=0}" "${S_LOC:=foreign}"
  VLESS_PORT="$CONN_PORT"
  if [ "$S_LOC" = ru ]; then
    WARP_FAIL_HINT="Без WARP один российский сервер не откроет заблокированные сайты. Варианты: схема из двух серверов (добавить зарубежный) или один зарубежный сервер."
    if [ "$EXIT_MODE" = direct ]; then die "для одного российского сервера нужен WARP: в режиме direct заблокированные сайты не откроются"; fi
  fi
  if command -v ss >/dev/null 2>&1; then ensure_ports_free; fi   # до установки пакетов: не трогаем сервер, если порты заняты чужим
  prep_base
  ensure_ports_free
  open_firewall
  DOMAIN="$S_DOMAIN"
  DECOY_PORT="$(decoy_port)"
  ACME_FWD="$(acme_forward_port)"
  if [ -n "$ACME_FWD" ]; then log "запросы на порт 80 для других доменов nginx будет пересылать в Caddy (127.0.0.1:$ACME_FWD)"; fi

  if [ "$S_DUCK" = 1 ]; then
    log "DuckDNS: $S_DOMAIN → $S_IP"
    duck_update "$S_SUB" "$S_IP" || die "DuckDNS ответил KO для «$S_SUB»: такого поддомена нет в аккаунте с этим токеном. Создай его на duckdns.org и запусти скрипт заново."
    setup_duck_keepalive
  fi
  log "Жду, пока $S_DOMAIN начнёт указывать на $S_IP"
  wait_dns "$S_DOMAIN" "$S_IP" || die "DNS для $S_DOMAIN так и не указал на $S_IP. Если домен свой (не DuckDNS) — пропиши A-запись вручную и запусти скрипт заново."

  log "Сайт-заглушка и сертификат Let's Encrypt"
  install -d -m 755 "$ACME_DIR"
  if [ "$S_LOC" = ru ]; then write_decoy_site ru; else write_decoy_site en; fi
  write_nginx_conf plain
  get_cert
  write_nginx_conf tls

  install_xray_single
  load_or_make_keys single
  S_UUID="$K_UUID"; S_PRIV="$K_PRIV"; S_PUB="$K_PUB"; S_SID="$K_SID"; S_PATH="$K_PATH"
  create_xray_user_and_service
  if [ "$EXIT_MODE" = warp ]; then ensure_warp; else warn "EXIT_MODE=direct: в интернет трафик будет выходить с IP этого сервера"; fi
  apply_single_config
  systemctl restart vless-xray
  sleep 3
  if ! systemctl is-active --quiet vless-xray; then journalctl -u vless-xray -n 40 --no-pager || true; die "xray не запустился (лог выше)"; fi

  log "Проверка: сайт-заглушка отвечает через порт $CONN_PORT"
  local code
  code="$(curl -sk --max-time 20 --resolve "$S_DOMAIN:$CONN_PORT:127.0.0.1" "https://$S_DOMAIN:$CONN_PORT/" -o /dev/null -w '%{http_code}' || true)"
  if [ "$code" != 200 ]; then die "через порт $CONN_PORT заглушка не отвечает (код $code). Смотри: journalctl -u vless-xray -n 50"; fi

  log "Самопроверка VPN"
  selftest_single

  local link
  link="vless://${S_UUID}@${S_IP}:${CONN_PORT}?encryption=none&security=reality&sni=${S_DOMAIN}&fp=${FP}&pbk=${S_PUB}&sid=${S_SID}&type=xhttp&path=${S_PATH//\//%2F}&mode=auto#vless-1srv"
  printf '%s\n' "$link" > "$STATE_DIR/link.txt"

  log "Мини-панель"
  PANEL_PORT=""
  SRV_IP="$S_IP"; SRV_DOMAIN="$S_DOMAIN"; RELAY_IP=""; RELAY_DOMAIN=""
  if [ "$S_LOC" = ru ]; then SCHEME_LABEL="Один сервер (Россия)"; else SCHEME_LABEL="Один сервер (за границей)"; fi
  LINK_TAG="vless-1srv"; ENV_FILE="single.env"
  install_panel || warn "панель не установилась (на ссылку это не влияет)"

  printf '\n@@PANEL_PORT=%s\n@@LINK=%s\n' "$PANEL_PORT" "$link"
  log "Сервер готов"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
