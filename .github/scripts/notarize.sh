#!/usr/bin/env bash
# Notarize a .app or .dmg and staple the ticket onto it.
#
# The app has to be notarized and stapled BEFORE it is copied into the DMG.
# Stapling it afterwards leaves the copy inside the image ticketless, so a user
# who drags it to /Applications gets an app Gatekeeper can only validate by
# reaching Apple over the network — which fails offline.
#
# notarytool will not accept a bundle directly, so a .app is zipped for the
# submission and the ticket is stapled back onto the bundle itself.
#
# Usage: notarize.sh <path-to-.app-or-.dmg> <keychain-profile>
set -euo pipefail

target="${1:?usage: notarize.sh <path-to-.app-or-.dmg> <keychain-profile>}"
profile="${2:?usage: notarize.sh <path-to-.app-or-.dmg> <keychain-profile>}"
[ -e "$target" ] || { echo "::error::no such path: $target"; exit 1; }

case "$target" in
  *.app)
    work="$(mktemp -d)"
    submission="$work/$(basename "${target%.app}").zip"
    ditto -c -k --sequesterRsrc --keepParent "$target" "$submission"
    ;;
  *.dmg | *.pkg | *.zip)
    submission="$target"
    ;;
  *)
    echo "::error::unsupported notarization target: $target"
    exit 1
    ;;
esac

scratch="$(mktemp -d)"
result="$scratch/submit.json"
log="$scratch/log.json"
status=""
id=""

for attempt in 1 2 3; do
  echo "Notarization attempt $attempt for $(basename "$target")..."
  submit_exit=0
  xcrun notarytool submit "$submission" \
    --keychain-profile "$profile" \
    --wait \
    --output-format json > "$result" || submit_exit=$?
  status="$(jq -r '.status // empty' "$result" 2>/dev/null || true)"
  id="$(jq -r '.id // empty' "$result" 2>/dev/null || true)"
  cat "$result" || true
  if [ "$submit_exit" -eq 0 ] && [ "$status" = "Accepted" ]; then
    break
  fi
  # The log names the actual rejected binary; without it the status alone is useless.
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" > "$log" || true
    cat "$log" || true
  fi
  if [ "$attempt" -lt 3 ]; then
    echo "Attempt $attempt failed, retrying in 30s..."
    sleep 30
  fi
done

if [ "$status" != "Accepted" ]; then
  echo "::error::Notarization failed for $target with status '${status:-unknown}'"
  exit 1
fi

xcrun stapler staple "$target"
xcrun stapler validate "$target"
