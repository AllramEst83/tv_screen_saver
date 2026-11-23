#!/usr/bin/env bash
# Copy the Pi scripts to the Pi (scp/ssh only, no sudo, never touches the TV).
#
#   PI_HOST=gemini-pi.local tool/pi/deploy.sh      (PI_HOST may be an IP)
#
# Puts tool/pi/*.sh and units/ in ~/tvsaver/pi/ and writes
# ~/.config/tvsaver/.env.example (no secrets). Then run on the Pi:
#   sudo bash ~/tvsaver/pi/setup_wifi.sh

set -eu
export MSYS_NO_PATHCONV=1

PI_HOST="${PI_HOST:-gemini-pi.local}"
PI_USER="${PI_USER:-allramest}"
KEY="${PI_KEY:-$HOME/.ssh/id_ed25519_claude}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8)
TARGET="$PI_USER@$PI_HOST"

cd "$(dirname "$0")"

ssh "${SSH_OPTS[@]}" "$TARGET" 'mkdir -p ~/tvsaver/pi/units ~/.config/tvsaver && chmod 700 ~/.config/tvsaver' ||
  { echo "cannot reach $TARGET (set PI_HOST to its IP if the name does not resolve)" >&2; exit 1; }

scp -q "${SSH_OPTS[@]}" setup_wifi.sh wifi_prefer.sh check_wifi.sh "$TARGET:tvsaver/pi/"
scp -q "${SSH_OPTS[@]}" units/tvsaver-wifi-prefer.service units/tvsaver-wifi-prefer.timer "$TARGET:tvsaver/pi/units/"

ssh "${SSH_OPTS[@]}" "$TARGET" 'chmod +x ~/tvsaver/pi/*.sh; cat > ~/.config/tvsaver/.env.example' <<'ENVEX'
# Copy to .env, fill in, then: chmod 600 ~/.config/tvsaver/.env
# Optional: with no .env (or an empty PSK) the saved profile password is left alone.
WIFI_FLOOR1_SSID=LightSpeed_Auto_Floor_1
WIFI_FLOOR1_PSK=
WIFI_FLOOR2_SSID=LightSpeed_Auto_Floor_2
WIFI_FLOOR2_PSK=
ENVEX

echo "deployed to $TARGET:~/tvsaver/pi/"
echo "next, on the Pi: sudo bash ~/tvsaver/pi/setup_wifi.sh --dry-run   (then without --dry-run)"
