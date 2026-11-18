#!/usr/bin/env bash
# ЗАРУБЕЖНЫЙ сервер: ретранслятор Xray (REALITY + XHTTP) и выход в интернет через Cloudflare WARP.
# Запускается оркестратором vless-setup.sh; переменные приходят export-строками перед этим текстом.
# Переменные (RU_IP, RELAY_IP, S_SUB и т.д.) приходят строками export от мастера, файлы состояния читаются через source:
# shellcheck disable=SC2153,SC1090,SC1091
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
TAG=RELAY
@@INCLUDE lib/common.sh@@

# ---------- DuckDNS ----------
duck_update() { # $1=поддомен $2=ip
  local r
  r="$(curl -fsS --max-time 25 "https://www.duckdns.org/update?domains=$1&token=${DUCKDNS_TOKEN}&ip=$2" 2>/dev/null || true)"
  [ "$r" = "OK" ]
}
setup_duck_keepalive() { # раз в 6 часов подтверждаем записи, чтобы DuckDNS не счёл домены заброшенными
  if [ "$RELAY_DUCK" != 1 ] && [ "$RU_DUCK" != 1 ]; then return 0; fi
  local f="$STATE_DIR/duck-keepalive.sh"
  umask 077
  {
    echo '#!/bin/sh'
    if [ "$RELAY_DUCK" = 1 ]; then echo "curl -fsS --max-time 25 'https://www.duckdns.org/update?domains=$RELAY_SUB&token=$DUCKDNS_TOKEN&ip=$RELAY_IP' >/dev/null 2>&1"; fi
    if [ "$RU_DUCK" = 1 ]; then echo "curl -fsS --max-time 25 'https://www.duckdns.org/update?domains=$RU_SUB&token=$DUCKDNS_TOKEN&ip=$RU_IP' >/dev/null 2>&1"; fi
    echo 'exit 0'
  } > "$f"
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

# ---------- Xray ----------
install_xray_relay() {
  local base="https://github.com/XTLS/Xray-core/releases/latest/download" want got
  case "$(uname -m)" in
    x86_64|amd64)  XZIP=Xray-linux-64.zip ;;
    aarch64|arm64) XZIP=Xray-linux-arm64-v8a.zip ;;
    *) die "архитектура $(uname -m) не поддерживается" ;;
  esac
  install -d -m 755 "$XDIR"
  log "Скачиваю Xray"
  dl "$base/$XZIP" "/tmp/$XZIP" || die "не удалось скачать Xray с GitHub"
  if dl "$base/$XZIP.dgst" "/tmp/$XZIP.dgst" 2>/dev/null; then
    want="$(awk -F'= *' '/^SHA2-256/{print $2; exit}' "/tmp/$XZIP.dgst" | tr -d ' \r\n')"
    got="$(sha256sum "/tmp/$XZIP" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then die "контрольная сумма архива Xray не совпала"; fi
  fi
  rm -rf /tmp/xray-unpack; install -d /tmp/xray-unpack
  unzip -oq "/tmp/$XZIP" -d /tmp/xray-unpack
  install -m 755 /tmp/xray-unpack/xray "$XRAY"
  install -m 644 /tmp/xray-unpack/geoip.dat /tmp/xray-unpack/geosite.dat "$XDIR/"
  log "Установлен $(xver)"
}
gen_relay_config() { # $1 = target|dest (имя поля в REALITY; зависит от версии Xray)
  local tkey="${1:-target}" udp_rule="" exit_ob
  if [ "$EXIT_MODE" = direct ]; then
    exit_ob='{ "tag": "exit", "protocol": "freedom", "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } } }'
  else
    exit_ob='{ "tag": "exit", "protocol": "socks", "settings": { "servers": [ { "address": "127.0.0.1", "port": 40000 } ] } }'
    udp_rule='{ "type": "field", "inboundTag": ["from-ru"], "network": "udp", "outboundTag": "block" },'
  fi
  cat <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [{
    "tag": "from-ru",
    "listen": "0.0.0.0",
    "port": ${RELAY_LISTEN_PORT:-443},
    "protocol": "vless",
    "settings": { "clients": [ { "id": "$RELAY_UUID" } ], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "$tkey": "127.0.0.1:$DECOY_PORT",
        "serverNames": [ "$RELAY_DOMAIN" ],
        "privateKey": "$RELAY_PRIV",
        "shortIds": [ "$RELAY_SID" ]
      },
      "xhttpSettings": { "path": "$RELAY_PATH", "mode": "auto" }
    }
  }],
  "outbounds": [
    { "tag": "block", "protocol": "blackhole" },
    $exit_ob
  ],
  "routing": {
    "rules": [
      $udp_rule
      { "type": "field", "inboundTag": ["from-ru"], "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "inboundTag": ["from-ru"], "outboundTag": "exit" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "block" }
    ]
  }
}
EOF
}
write_relay_config() {
  local tkey tmp=/tmp/relay-config.json
  for tkey in target dest; do
    gen_relay_config "$tkey" > "$tmp"
    if XRAY_LOCATION_ASSET="$XDIR" "$XRAY" run -test -config "$tmp" >/tmp/xray-test.log 2>&1; then
      install -m 640 -o root -g xray "$tmp" "$XDIR/config.json"
      return 0
    fi
  done
  cat /tmp/xray-test.log
  die "Xray не принял конфиг (вывод выше)"
}

@@INCLUDE lib/warp.sh@@

# ---------- пакет файлов для российского сервера (GitHub из РФ может не открываться) ----------
build_bundle() {
  local b="$STATE_DIR/ru-bundle" zip base="https://github.com/XTLS/Xray-core/releases/latest/download"
  local geo="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
  rm -rf "$b" "$STATE_DIR/ru-bundle.tgz"; install -d "$b"
  case "$RU_ARCH" in
    x86_64|amd64)  zip=Xray-linux-64.zip ;;
    aarch64|arm64) zip=Xray-linux-arm64-v8a.zip ;;
    *) die "российский сервер: архитектура $RU_ARCH не поддерживается" ;;
  esac
  if [ "$zip" = "$XZIP" ] && [ -s "/tmp/$XZIP" ]; then cp "/tmp/$XZIP" "$b/xray.zip"; else dl "$base/$zip" "$b/xray.zip" || die "не скачался Xray для российского сервера"; fi
  # расширенные списки runetfreedom (ru-blocked и др.) — желательны, но не критичны: без них RU-сервер возьмёт упрощённые правила
  if dl "$geo/geoip.dat" "$b/geoip.dat" && dl "$geo/geosite.dat" "$b/geosite.dat" \
     && [ "$(wc -c < "$b/geoip.dat")" -gt 100000 ] && [ "$(wc -c < "$b/geosite.dat")" -gt 100000 ]; then
    log "списки runetfreedom скачаны"
  else
    warn "не удалось скачать списки runetfreedom — российский сервер будет использовать упрощённые правила"
    rm -f "$b/geoip.dat" "$b/geosite.dat"
  fi
  tar -C "$b" -czf "$STATE_DIR/ru-bundle.tgz" .
  rm -rf "$b"
}

main() {
  trap 'die "сбой на строке $LINENO: $BASH_COMMAND"' ERR
  : "${RELAY_DUCK:=0}" "${RU_DUCK:=0}" "${RELAY_LISTEN_PORT:=443}"
  VLESS_PORT="$RELAY_LISTEN_PORT"
  if command -v ss >/dev/null 2>&1; then ensure_ports_free; fi   # до установки пакетов: не трогаем сервер, если порты заняты чужим
  prep_base
  ensure_ports_free
  open_firewall
  DOMAIN="$RELAY_DOMAIN"
  DECOY_PORT="$(decoy_port)"
  ACME_FWD="$(acme_forward_port)"
  if [ -n "$ACME_FWD" ]; then log "запросы на порт 80 для других доменов nginx будет пересылать в Caddy (127.0.0.1:$ACME_FWD)"; fi

  log "DuckDNS: записи A для обоих серверов"
  if [ "$RELAY_DUCK" = 1 ]; then
    duck_update "$RELAY_SUB" "$RELAY_IP" || die "DuckDNS ответил KO для «$RELAY_SUB»: такого поддомена нет в аккаунте с этим токеном. Создай его на duckdns.org и запусти скрипт заново."
  fi
  if [ "$RU_DUCK" = 1 ]; then
    duck_update "$RU_SUB" "$RU_IP" || die "DuckDNS ответил KO для «$RU_SUB»: такого поддомена нет в аккаунте с этим токеном. Создай его на duckdns.org и запусти скрипт заново."
  fi
  log "Жду, пока $RELAY_DOMAIN начнёт указывать на $RELAY_IP"
  wait_dns "$RELAY_DOMAIN" "$RELAY_IP" || die "DNS для $RELAY_DOMAIN так и не указал на $RELAY_IP. Если домен свой (не DuckDNS) — пропиши A-запись вручную и запусти скрипт заново."
  setup_duck_keepalive

  log "Сайт-заглушка и сертификат Let's Encrypt"
  install -d -m 755 "$ACME_DIR"
  write_decoy_site en
  write_nginx_conf plain
  get_cert
  write_nginx_conf tls

  install_xray_relay
  load_or_make_keys relay
  RELAY_UUID="$K_UUID"; RELAY_PRIV="$K_PRIV"; RELAY_PUB="$K_PUB"; RELAY_SID="$K_SID"; RELAY_PATH="$K_PATH"
  create_xray_user_and_service
  write_relay_config

  if [ "$EXIT_MODE" = warp ]; then
    ensure_warp
  else
    warn "EXIT_MODE=direct: в интернет трафик будет выходить с IP зарубежного сервера"
  fi

  systemctl restart vless-xray
  sleep 3
  if ! systemctl is-active --quiet vless-xray; then journalctl -u vless-xray -n 40 --no-pager || true; die "xray не запустился (лог выше)"; fi

  log "Проверка: сайт-заглушка отвечает через порт $VLESS_PORT (REALITY → nginx)"
  local code
  code="$(curl -sk --max-time 20 --resolve "$RELAY_DOMAIN:$VLESS_PORT:127.0.0.1" "https://$RELAY_DOMAIN:$VLESS_PORT/" -o /dev/null -w '%{http_code}' || true)"
  if [ "$code" != 200 ]; then die "через порт $VLESS_PORT заглушка не отвечает (код $code). Смотри: journalctl -u vless-xray -n 50"; fi

  log "Готовлю файлы для российского сервера"
  build_bundle

  if systemctl cat vless-panel.service >/dev/null 2>&1; then
    systemctl disable --now vless-panel >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/link.txt" "$STATE_DIR/panel.json"
    log "панель от прошлой установки на этом сервере отключена (он теперь ретранслятор)"
  fi
  printf '\n@@RELAY_UUID=%s\n@@RELAY_PUB=%s\n@@RELAY_SID=%s\n@@RELAY_PATH=%s\n' "$RELAY_UUID" "$RELAY_PUB" "$RELAY_SID" "$RELAY_PATH"
  log "Зарубежный сервер готов"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
