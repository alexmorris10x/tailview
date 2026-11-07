#!/bin/zsh
# Composes the five Mac Remote screenshots for one device from its raw captures.
# Usage: compose_all.sh iphone|ipad <raw dir>   (raw dir holds 01-control.png ... 05-access.png)
set -euo pipefail
here=${0:A:h}; device=$1; raw=$2
py=${PYTHON:-/opt/homebrew/bin/python3}   # needs Pillow
bg="#6541aa"                              # the site's violet
if [[ $device == ipad ]]; then out=$here/../ipad-13; spec=ipad-landscape; on="iPad"
else out=$here/../iphone-6.9; spec=iphone-landscape; on="iPhone"; fi
mkdir -p $out
c() { "$py" "$here/compose.py" --device $spec --bg $bg "$@"; }
c --shot $raw/01-control.png --out $out/01.png --headline "Control your Mac from $on" \
  --subline "Your whole Mac desktop, live in your hand."
c --shot $raw/02-see-hear.png --out $out/02.png --headline "See and hear your Mac" \
  --subline "Watch the screen and listen to Mac sound, wherever you are."
c --shot $raw/03-keyboard.png --out $out/03.png --headline "Keyboard, mouse and trackpad" \
  --subline "Type, click, scroll and drag, with shortcuts and window controls."
c --shot $raw/04-setup.png --out $out/04.png --headline "Private over your tailnet" \
  --subline "Works with Tailscale. No account and no hosted server in between."
c --shot $raw/05-access.png --out $out/05.png --headline "Try 7 days free, then \$9.99 once" \
  --subline "No subscription, and nothing is charged automatically."
