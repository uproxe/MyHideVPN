# ---------- Cloudflare WARP: бесплатный выходной адрес, чтобы IP сервера-выхода нигде не светился ----------
# Вызывающий скрипт может задать WARP_FAIL_HINT — что посоветовать, если WARP не встанет.
warp_ok() { curl -s --max-time 15 --proxy socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -Eq '^warp=(on|plus)'; }
install_warp() {
  local suite fb=bookworm ring="${KEYRING_DIR:-/usr/share/keyrings}/cloudflare-warp-archive-keyring.gpg"
  local list="${APT_LIST_DIR:-/etc/apt/sources.list.d}/cloudflare-client.list"
  local hint="${WARP_FAIL_HINT:-Запасной вариант: EXIT_MODE=direct bash vless-setup.sh}"
  case "${ID:-}" in debian) fb=bookworm ;; *) fb=jammy ;; esac
  suite="${VERSION_CODENAME:-$fb}"
  install -d -m 755 "$(dirname "$ring")" "$(dirname "$list")"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o "$ring" \
    || die "не удалось скачать ключ репозитория Cloudflare WARP. $hint"
  if ! curl -fs --max-time 20 -o /dev/null "https://pkg.cloudflareclient.com/dists/$suite/Release"; then
    warn "репозиторий WARP не знает релиз «$suite», беру «$fb»"
    suite="$fb"
  fi
  echo "deb [signed-by=$ring] https://pkg.cloudflareclient.com/ $suite main" > "$list"
  $APT update >/dev/null || true
  if ! $APT install cloudflare-warp >/tmp/warp-install.log 2>&1; then
    if [ "$suite" != "$fb" ]; then
      warn "пакет WARP для «$suite» не встал, пробую сборку для «$fb»"
      echo "deb [signed-by=$ring] https://pkg.cloudflareclient.com/ $fb main" > "$list"
      $APT update >/dev/null || true
      $APT install cloudflare-warp >/tmp/warp-install.log 2>&1 || { tail -n 15 /tmp/warp-install.log; die "не удалось установить cloudflare-warp. $hint"; }
    else
      tail -n 15 /tmp/warp-install.log; die "не удалось установить cloudflare-warp. $hint"
    fi
  fi
}
configure_warp() {
  local i hint="${WARP_FAIL_HINT:-Можно запустить скрипт заново с EXIT_MODE=direct — тогда выход будет с IP сервера (хуже: этот адрес быстрее попадёт в блок).}"
  w() { warp-cli --accept-tos "$@"; }
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  sleep 4
  for i in 1 2 3 4 5; do
    if w registration new >/dev/null 2>&1 || w register >/dev/null 2>&1; then break; fi
    sleep 3
  done
  w mode proxy >/dev/null 2>&1 || w set-mode proxy >/dev/null 2>&1 || true
  w proxy port 40000 >/dev/null 2>&1 || w set-proxy-port 40000 >/dev/null 2>&1 || true
  w connect >/dev/null 2>&1 || true
  for i in $(seq 1 25); do
    if warp_ok; then return 0; fi
    sleep 3
  done
  warp-cli status 2>&1 | sed -n '1,8p' || true
  die "WARP не поднялся (хостер может не давать нужных прав или блокировать Cloudflare). $hint"
}
ensure_warp() {
  log "Cloudflare WARP (выходной адрес)"
  if warp_ok; then log "WARP уже работает"; else install_warp; configure_warp; log "WARP работает"; fi
}
