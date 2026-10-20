#!/bin/zsh
# Runs a scripted test of main.swift in a throwaway app ("Test Tabs", bundle ID local.webapptabs-test,
# which Link Router ignores). Prints the test log; screenshots end up next to it.
#
# usage: tools/test.sh <steps.swift> [home-url] [defaults.json]
#   steps.swift   defines `let steps: [(Double, @MainActor () -> Void)]` – (seconds after launch, action);
#                 see tools/example-steps.swift and the helpers in tools/harness.py. End with NSApp.terminate(nil).
#   home-url      the app's WebAppURL (default https://example.com/)
#   defaults.json settings to start with, e.g. {"restoreTabs": true, "pinnedPages": [...], "session": [...]}
#                 (pinnedPages/session are stored as JSON data, like the app does)
set -euo pipefail
ROOT=${0:A:h:h}
STEPS=${1:?steps file}; STEPS=${STEPS:A}
HOME_URL=${2:-https://example.com/}
DEFAULTS=${3:-}
OUT=${TMPDIR:-/tmp}/webapptabs-test
ID=local.webapptabs-test

mkdir -p "${OUT:?}/Test.app/Contents/MacOS"
python3 "$ROOT/tools/harness.py" "$OUT" "$STEPS"
rm -f "${OUT:?}/Test.app/Contents/MacOS/test"
if ! swiftc -O "$OUT/main.swift" -o "$OUT/Test.app/Contents/MacOS/test" 2> "$OUT/build.log"; then
  grep -E 'error' -A3 "$OUT/build.log"; exit 1
fi
cat > "$OUT/Test.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Test Tabs</string>
  <key>CFBundleExecutable</key><string>test</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>WebAppURL</key><string>$HOME_URL</string>
</dict></plist>
EOF
codesign --force --sign - "$OUT/Test.app" 2>/dev/null

defaults delete "$ID" 2>/dev/null || true
if [[ -n $DEFAULTS ]]; then
  python3 - "$ID" "$DEFAULTS" <<'EOF'
import json, plistlib, subprocess, sys
settings = json.load(open(sys.argv[2]))
for key in ('pinnedPages', 'session'):
    if key in settings: settings[key] = json.dumps(settings[key]).encode()
subprocess.run(['defaults', 'import', sys.argv[1], '-'], input=plistlib.dumps(settings), check=True)
EOF
fi

rm -f "${OUT:?}/test.log"
open -W "$OUT/Test.app"
cat "$OUT/test.log" 2>/dev/null || echo "(no log – did the steps run? check that the last step calls NSApp.terminate(nil))"
defaults delete "$ID" 2>/dev/null || true
ls "$OUT"/*.png(N) 2>/dev/null | sed 's/^/screenshot: /'
