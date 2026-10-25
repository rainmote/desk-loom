#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/.build"
# Build signed bundles on local storage. Network volumes may create AppleDouble
# ._* sidecars inside the bundle, which codesign treats as unsigned resources.
build_stage="$(mktemp -d "${TMPDIR:-/tmp}/deskloom-native.XXXXXX")"
trap 'rm -rf "$build_stage"' EXIT
app_dir="$build_stage/DeskLoom.app"
# TCC tracks the designated code requirement. Ad-hoc signatures use a new
# CDHash on every rebuild, leaving enabled permission rows tied to old code.
# Pin an existing development identity; never silently fall back to ad-hoc.
signing_identity="$(python3 - "$project_dir" <<'PY'
import os, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
pin = root / '.runtime' / 'signing-identity'
result = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                        check=True, capture_output=True, text=True)
identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', result.stdout, re.M)
selected = os.environ.get('DESKLOOM_SIGNING_IDENTITY') or os.environ.get('COMPUTER_USE_SIGNING_IDENTITY')
pinned = pin.read_text().strip() if pin.exists() else None
if not selected:
    selected = pinned
if not selected:
    selected = next((digest for digest, name in identities
                     if name.startswith('Apple Development:')), None)
if not selected:
    selected = next((digest for digest, name in identities
                     if name.startswith('Developer ID Application:')), None)
match = next((digest for digest, name in identities if selected in (digest, name)), None)
if not match:
    raise SystemExit('No valid pinned signing identity. Configure an Apple Development certificate or DESKLOOM_SIGNING_IDENTITY; refusing an ad-hoc rebuild that would invalidate permissions.')
if pinned and match != pinned:
    raise SystemExit('Signing identity differs from the pinned certificate; refusing an identity change that could invalidate permissions.')
pin.parent.mkdir(parents=True, exist_ok=True)
if not pin.exists() or pin.read_text().strip() != match:
    pin.write_text(match + '\n')
print(match)
PY
)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
bash "$project_dir/scripts/build-icons.sh" "$app_dir/Contents/Resources"
cp -X "$project_dir/scripts/dlm" "$project_dir/scripts/rpc.py" "$project_dir/scripts/llm.py" "$app_dir/Contents/Resources/"
cp -X "$project_dir/references/permissionflow/LICENSE" "$app_dir/Contents/Resources/PermissionFlow-LICENSE.txt"
chmod 755 "$app_dir/Contents/Resources/dlm"
python3 - "$project_dir" "$app_dir/Contents/Resources/BuildConfiguration.json" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(json.dumps({'sourceDirectory': sys.argv[1], 'pythonExecutable': sys.executable}))
PY
mkdir -p "$project_dir/.build/compiler-temp" "$project_dir/.build/swift-module-cache"
# Keep large compiler caches on the project volume; only the signed bundle
# needs local staging to avoid network-volume AppleDouble resources.
TMPDIR="$project_dir/.build/compiler-temp" xcrun swiftc -swift-version 5 -O -g \
  -module-cache-path "$project_dir/.build/swift-module-cache" \
  "$project_dir"/native/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework ScreenCaptureKit -framework Network -framework CryptoKit \
  -o "$app_dir/Contents/MacOS/DeskLoom"
# Keep the existing internal bundle/signing identifier. Renaming this identity
# would invalidate macOS privacy grants even though the display name changes.
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.geb.ComputerUsePrototype</string>
<key>CFBundleName</key><string>DeskLoom</string>
<key>CFBundleDisplayName</key><string>DeskLoom</string>
<key>CFBundleExecutable</key><string>DeskLoom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>19</string>
<key>CFBundleShortVersionString</key><string>0.11.0</string>
<key>CFBundleIconFile</key><string>DeskLoomIconC</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>为本地电脑控制捕获当前明确选择的应用窗口。</string>
</dict></plist>
PLIST
python3 - "$app_dir/Contents/Info.plist" <<'PY'
import json, pathlib, plistlib, sys
selection = 'C'
support = pathlib.Path.home() / 'Library/Application Support'
preferences = support / 'DeskLoom/appearance.json'
if not preferences.exists():
    preferences = support / 'ComputerUsePrototype/appearance.json'
try:
    value = json.loads(preferences.read_text()).get('selectedIcon')
    if value in ('C', 'D'):
        selection = value
except (OSError, ValueError):
    pass
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info['CFBundleIconFile'] = 'DeskLoomIcon' + selection
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign "$signing_identity" --timestamp=none --identifier local.geb.ComputerUsePrototype "$app_dir"
codesign --verify --strict "$app_dir"
python3 "$project_dir/scripts/install-native.py" "$app_dir"
