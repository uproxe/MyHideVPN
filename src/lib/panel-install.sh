# ---------- мини-панель (только 127.0.0.1, вход через SSH-туннель) ----------
# Перед вызовом задать: SRV_IP SRV_DOMAIN CONN_PORT SCHEME_LABEL LINK_TAG ENV_FILE, по желанию RELAY_IP RELAY_DOMAIN.
install_panel() {
  local pdir="${PANEL_DIR:-/opt/vless-panel}" port token
  install -d -m 700 "$pdir"
  cat > "$pdir/panel.py" <<'__PANEL_PY_END__'
@@INCLUDE lib/panel.py@@
__PANEL_PY_END__
  systemctl stop vless-panel >/dev/null 2>&1 || true
  if [ -s "$STATE_DIR/panel_port" ] && [ "$(cat "$STATE_DIR/panel_port")" != "$CONN_PORT" ]; then port="$(cat "$STATE_DIR/panel_port")"; else
    port="$(pick_port 8088 8089 18088 28088)" || { warn "нет свободного порта для панели — пропускаю"; PANEL_PORT=""; return 0; }
    printf '%s' "$port" > "$STATE_DIR/panel_port"
  fi
  token="$(openssl rand -hex 16)"
  umask 077
  cat > "$STATE_DIR/panel.json" <<EOF
{ "srv_ip": "$SRV_IP", "srv_domain": "$SRV_DOMAIN", "conn_port": $CONN_PORT,
  "relay_ip": "${RELAY_IP:-}", "relay_domain": "${RELAY_DOMAIN:-}",
  "scheme_label": "$SCHEME_LABEL", "link_tag": "$LINK_TAG", "env_file": "$ENV_FILE", "fp": "$FP",
  "exit_mode": "$EXIT_MODE", "xdir": "$XDIR", "state_dir": "$STATE_DIR", "port": $port, "token": "$token" }
EOF
  umask 022
  cat > "$UNIT_DIR/vless-panel.service" <<EOF
[Unit]
Description=vless-setup mini panel (127.0.0.1 only)
After=network.target

[Service]
ExecStart=/usr/bin/python3 $pdir/panel.py $STATE_DIR/panel.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vless-panel >/dev/null 2>&1 || true
  systemctl restart vless-panel || true
  sleep 2
  if curl -s --max-time 5 "http://127.0.0.1:$port/" | grep -q 'vless://'; then
    log "панель работает на 127.0.0.1:$port"
    PANEL_PORT="$port"
  else
    warn "панель не ответила (на ссылку и VPN это не влияет): journalctl -u vless-panel -n 20"
    PANEL_PORT=""
  fi
}
