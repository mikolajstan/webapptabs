#!/bin/zsh
# usage:
#   ./make-app.sh ~/Applications/Gmail.app [name]   new Tabs app from a Safari web app (copies its URL and icon)
#                                                   → ~/Applications/Gmail Tabs.app
#   ./make-app.sh --all                             rebuild every Tabs app after changing main.swift
#                                                   (running ones are restarted; their tabs are restored)
# The Safari web app is only needed for the first build; --all reads everything from the Tabs apps.
set -euo pipefail
cd "$(dirname "$0")"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null }

# build_app <name> <url> <icon.icns or "">
build_app() {
  local NAME=$1 URL=$2 ICON=$3
  local APP="$HOME/Applications/$NAME.app"
  local ID="local.webapptabs.$(echo "$NAME" | tr -cd '[:alnum:]')"
  local WAS_RUNNING=$(pgrep -f "$APP/Contents/MacOS/WebAppTabs" || true)
  [[ -n $WAS_RUNNING ]] && pkill -f "$APP/Contents/MacOS/WebAppTabs" && sleep 1
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp WebAppTabs "$APP/Contents/MacOS/"
  [[ -n $ICON ]] && cp "$ICON" "$APP/Contents/Resources/ApplicationIcon.icns"
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>WebAppTabs</string>
  <key>CFBundleIconFile</key><string>ApplicationIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>WebAppURL</key><string>$URL</string>
  <!-- accept links sent by Link Router; rank None so it is never picked as the default browser -->
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web site URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    <key>LSHandlerRank</key><string>None</string>
  </dict></array>
</dict></plist>
EOF
  codesign --force --sign - "$APP" 2>/dev/null
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
  [[ -n $WAS_RUNNING ]] && open "$APP"
  echo "Built $APP → $URL${WAS_RUNNING:+ (restarted)}"
}

swiftc -O main.swift -o WebAppTabs

if [[ ${1:-} == --all ]]; then
  for APP in ~/Applications/*.app(N); do
    [[ $(plist "$APP" CFBundleIdentifier) == local.webapptabs.* ]] || continue
    build_app "$(plist "$APP" CFBundleName)" "$(plist "$APP" WebAppURL)" ""
  done
else
  SRC=${1:?path to a Safari web app, or --all}
  NAME=${2:-"$(plist "$SRC" CFBundleName) Tabs"}
  build_app "$NAME" "$(plist "$SRC" Manifest:start_url)" "$SRC/Contents/Resources/ApplicationIcon.icns"
fi
