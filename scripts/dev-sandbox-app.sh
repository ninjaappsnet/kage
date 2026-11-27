#!/usr/bin/env bash
# Runs a Debug Kage that cannot touch the Kage you work in, for agents and
# humans checking UI changes. Isolation:
# - its own bundle id (net.ninjaapps.kage.devsandbox), so its own UserDefaults
#   (sidebar state, layouts, window frames) and its own app instance;
# - HOME, XDG_CONFIG_HOME and ZMX_DIR under .build/dev-sandbox, so its own
#   config, worktree storage and zmx sessions (it never attaches to yours).
#   ssh still uses your real ~/.ssh (OpenSSH reads the passwd home).
# Seeded once from your config: remote hosts and the repository list only
# (never sync, Claude accounts or global settings).
#
#   scripts/dev-sandbox-app.sh prepare     # copy the Debug build (run make build-app first)
#   scripts/dev-sandbox-app.sh launch      # start it (prepares if needed)
#   scripts/dev-sandbox-app.sh snapshot T  # save its windows to .build/dev-sandbox/shots/T-<n>.png
#   scripts/dev-sandbox-app.sh defaults K V # write a bool/string default (e.g. collapse a group)
#   scripts/dev-sandbox-app.sh remote CMD  # drive the remote files UI (RemoteKageFilesDebugCommands)
#   scripts/dev-sandbox-app.sh quit        # quit it and end its zmx sessions
#   scripts/dev-sandbox-app.sh reset       # quit and delete the sandbox
#
# Extra environment for launch: KAGE_SANDBOX_ENV="KEY=value KEY2=value2", e.g.
# KAGE_REMOTE_CLI_PATH_OVERRIDE=/Users/me/kage-dev/supacode (Debug builds only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$ROOT/.build/dev-sandbox"
APP="$SANDBOX/Kage Sandbox.app"
SOURCE_APP="$ROOT/.build/DerivedData/Build/Products/Debug/Kage.app"
BUNDLE_ID="net.ninjaapps.kage.devsandbox"
SANDBOX_HOME="$SANDBOX/home"
SHOTS="$SANDBOX/shots"
ZMX_SANDBOX_DIR="$SANDBOX/zmx"

prepare() {
  [ -d "$SOURCE_APP" ] || { echo "No Debug build at $SOURCE_APP; run make build-app" >&2; exit 1; }
  mkdir -p "$SANDBOX"
  rm -rf "$APP"
  cp -cR "$SOURCE_APP" "$APP"
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "Kage Sandbox" "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "Kage Sandbox" "$APP/Contents/Info.plist" 2>/dev/null || true
  # Sparkle must never update or replace the sandbox copy.
  plutil -replace SUEnableAutomaticChecks -bool NO "$APP/Contents/Info.plist" 2>/dev/null || true
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  echo "prepared $APP"
}

seed() {
  local config="$SANDBOX_HOME/.config/kage"
  [ -d "$config" ] && return
  mkdir -p "$config" "$SHOTS" "$ZMX_SANDBOX_DIR"
  local real="${XDG_CONFIG_HOME:-$HOME/.config}/kage"
  for file in remote-hosts.json repos.json routes.json; do
    [ -f "$real/$file" ] && cp "$real/$file" "$config/$file"
  done
  # Mark the relocation as done so launch migrations have nothing to move.
  touch "$config/.relocated"
  echo "seeded $config"
}

pid() { pgrep -f "$APP/Contents/MacOS/" | head -1 || true; }

case "${1:-}" in
  prepare) prepare ;;
  launch)
    # Re-copy when the Debug build is newer, so launch never runs a stale copy.
    if [ ! -d "$APP" ] || [ "$SOURCE_APP/Contents/MacOS/Kage.debug.dylib" -nt "$APP/Contents/MacOS/Kage.debug.dylib" ]; then
      prepare
    fi
    seed
    if [ -n "$(pid)" ]; then echo "already running (pid $(pid))"; exit 0; fi
    extra_env=()
    for pair in ${KAGE_SANDBOX_ENV:-}; do extra_env+=(--env "$pair"); done
    open -n -g "$APP" ${extra_env[@]+"${extra_env[@]}"} \
      --env HOME="$SANDBOX_HOME" \
      --env XDG_CONFIG_HOME="$SANDBOX_HOME/.config" \
      --env ZMX_DIR="$ZMX_SANDBOX_DIR" \
      --env KAGE_DEBUG_SNAPSHOT_DIR="$SHOTS" \
      --stdout "$SANDBOX/app.log" --stderr "$SANDBOX/app.log"
    for _ in $(seq 1 40); do [ -n "$(pid)" ] && break; sleep 0.25; done
    echo "launched pid $(pid); log $SANDBOX/app.log"
    ;;
  snapshot)
    tag="${2:-snapshot}"
    rm -f "$SHOTS/$tag.done"
    osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('net.ninjaapps.kage.debug.snapshot', '$tag', \$(), true)" >/dev/null
    for _ in $(seq 1 40); do [ -f "$SHOTS/$tag.done" ] && break; sleep 0.25; done
    [ -f "$SHOTS/$tag.done" ] || { echo "no snapshot (is the sandbox app running?)" >&2; exit 1; }
    cat "$SHOTS/$tag.done"; echo
    ;;
  remote)
    command="${2:?usage: remote <command>}"
    osascript -l JavaScript - "$command" >/dev/null <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    'net.ninjaapps.kage.debug.remote-files', argv[0], $(), true);
}
JXA
    ;;
  defaults)
    key="$2"; value="$3"
    case "$value" in
      true|false|YES|NO) defaults write "$BUNDLE_ID" "$key" -bool "$value" ;;
      *) defaults write "$BUNDLE_ID" "$key" -string "$value" ;;
    esac
    ;;
  quit)
    p="$(pid)"
    [ -n "$p" ] && kill "$p" && echo "quit pid $p"
    # Sessions started by the sandbox live only in its own ZMX_DIR.
    ZMX_DIR="$ZMX_SANDBOX_DIR" "$APP/Contents/Resources/zmx/zmx" list 2>/dev/null \
      | sed -n 's/^.*name=\([^[:space:]]*\).*$/\1/p' \
      | while read -r session; do ZMX_DIR="$ZMX_SANDBOX_DIR" "$APP/Contents/Resources/zmx/zmx" kill "$session" >/dev/null 2>&1 || true; done
    ;;
  reset)
    "$0" quit || true
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$SANDBOX"
    echo "sandbox removed"
    ;;
  *) sed -n '2,20p' "$0"; exit 64 ;;
esac
