#!/usr/bin/env bash
# Abre o MangoCUT no simulador em cada tela do modo de demonstração e tira um screenshot.
# Uso: scripts/simulator-screenshots.sh <MangoCUT.app do simulador> <pasta de saída>
set -euo pipefail

APP="$1"
OUT="$2"
BUNDLE_ID="com.mangocut.MangoCUT"
SCREENS=(home editor filters effects text transition speed export)
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime, items in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in items]
phones = [d for d in devices if d["name"].startswith("iPhone")]
preferred = [d for d in phones if d["name"] in ("iPhone 16", "iPhone 16 Pro", "iPhone 15", "iPhone 15 Pro")]
print((preferred or phones)[0]["udid"])
')
echo "Simulador: $(xcrun simctl list devices | grep "$UDID")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

for screen in "${SCREENS[@]}"; do
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" --demo-screen "$screen" >/dev/null
  if [ "$screen" = "home" ]; then
    # A primeira abertura gera os vídeos sintéticos e o projeto de demonstração.
    DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
    for _ in $(seq 1 90); do
      if ls "$DATA"/Documents/Projetos/*/draft_content.json >/dev/null 2>&1; then break; fi
      sleep 1
    done
    sleep 4
  else
    sleep 10
  fi
  xcrun simctl io "$UDID" screenshot "$OUT/$screen.png" >/dev/null
  echo "ok: $screen"
done
