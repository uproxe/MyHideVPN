#!/usr/bin/env bash
# Проверка всех вариантов конфигов настоящим Xray (xray run -test).
#
#   XRAY_DIR=/path/to/dir bash tests/validate-configs.sh
#
# В XRAY_DIR должны лежать: xray, geoip.dat, geosite.dat (лучше списки runetfreedom — тогда проверяется
# и полный набор правил; со стандартными списками Xray полный набор ожидаемо отклоняется, и скрипт
# на серверах переходит к упрощённому — это тоже проверяется).
# Переменные задаются в подоболочках и читаются функциями из подгруженных серверных скриптов:
# shellcheck disable=SC2030,SC2031,SC2034,SC2153
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${XRAY_DIR:?укажите XRAY_DIR — каталог с xray, geoip.dat, geosite.dat}"
XRAY="$XRAY_DIR/xray"
[ -x "$XRAY" ] || { echo "нет $XRAY" >&2; exit 2; }
for f in single relay entry; do [ -f "$ROOT/dist/$f.sh" ] || { echo "сначала соберите: python3 tools/build.py" >&2; exit 2; }; done

W="$(mktemp -d "${TMPDIR:-/tmp}/vless-cfg.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/st-single" "$W/st-relay" "$W/st-entry"
export FP=firefox

# --- генерация (функции берутся из собранных серверных скриптов) ---
(
  export STATE_DIR="$W/st-single" XDIR="$XRAY_DIR" S_IP=203.0.113.10 S_DOMAIN=vps.example.org DECOY_PORT=18443
  # shellcheck disable=SC1091
  source "$ROOT/dist/single.sh"; set +e; trap - ERR
  load_or_make_keys single
  S_UUID=$K_UUID S_PRIV=$K_PRIV S_SID=$K_SID S_PATH=$K_PATH
  for em in warp direct; do for cp in 443 2053; do for v in 1 2 3; do
    EXIT_MODE=$em CONN_PORT=$cp gen_single_config target "$v" > "$W/single-$em-$cp-set$v.json"
  done; done; done
)
(
  export STATE_DIR="$W/st-relay" XDIR="$XRAY_DIR" RELAY_IP=203.0.113.30 RELAY_DOMAIN=relay.example.org DECOY_PORT=18443
  # shellcheck disable=SC1091
  source "$ROOT/dist/relay.sh"; set +e; trap - ERR
  load_or_make_keys relay
  RELAY_UUID=$K_UUID RELAY_PRIV=$K_PRIV RELAY_SID=$K_SID RELAY_PATH=$K_PATH
  for em in warp direct; do for rp in 443 2053; do
    EXIT_MODE=$em RELAY_LISTEN_PORT=$rp gen_relay_config target > "$W/relay-$em-$rp.json"
  done; done
  printf 'RELAY_UUID=%s\nRELAY_PUB=%s\nRELAY_SID=%s\nRELAY_PATH=%s\n' "$K_UUID" "$K_PUB" "$K_SID" "$K_PATH" > "$W/relay.vars"
)
(
  export STATE_DIR="$W/st-entry" XDIR="$XRAY_DIR" RU_IP=198.51.100.20 RU_DOMAIN=entry.example.org \
         RELAY_IP=203.0.113.30 RELAY_DOMAIN=relay.example.org DECOY_PORT=9443 EXIT_MODE=warp
  # shellcheck disable=SC1091
  source "$ROOT/dist/entry.sh"; set +e; trap - ERR
  # shellcheck disable=SC1091
  . "$W/relay.vars"
  load_or_make_keys ru
  RU_UUID=$K_UUID RU_PRIV=$K_PRIV RU_SID=$K_SID RU_PATH=$K_PATH
  for cp in 443 8443; do for v in 1 2 3; do
    RU_LISTEN_PORT=$cp RELAY_PORT=2053 gen_ru_config target "$v" > "$W/entry-$cp-set$v.json"
  done; done
)

# --- проверка ---
pass=0; fail=0; full_ok=0
for f in "$W"/*.json; do
  n="$(basename "$f" .json)"
  if XRAY_LOCATION_ASSET="$XRAY_DIR" "$XRAY" run -test -config "$f" >"$W/out.txt" 2>&1 && grep -q 'Configuration OK' "$W/out.txt"; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$n"
    case "$n" in *set1) full_ok=1 ;; esac
  else
    case "$n" in
      *set1) printf '  skip  %s (полный набор правил требует списков runetfreedom)\n' "$n" ;;
      *) fail=$((fail + 1)); printf '  FAIL  %s\n' "$n"; tail -n 3 "$W/out.txt" | sed 's/^/        /' ;;
    esac
  fi
done
echo "Итог: $pass прошло, $fail упало$([ "$full_ok" = 1 ] && echo '' || echo ' (полный набор правил не проверялся)')"
[ "$fail" = 0 ]
