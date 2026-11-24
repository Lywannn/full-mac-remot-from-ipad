#!/bin/bash
# Builds iPadMode.app and the two Dock applets into an APFS stage directory (never under build/ on the exFAT
# volume: codesign rejects AppleDouble ._* files). Prints nothing on stdout except progress lines.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${HOME}/Library/Caches/ipadmode-build/stage"
INSTALLED_CLI="${HOME}/Applications/iPadMode/iPadMode.app/Contents/MacOS/ipadmode"
APPLETS=("iPad Remote:ipad.landscape:2f6fed" "Layar Normal:display.2:2e8b57")

echo "build-app: stage directory ${STAGE}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"

echo "build-app: swift build (release, arm64)"
"${ROOT}/scripts/sw" build -c release --arch arm64
BIN_DIR="$("${ROOT}/scripts/sw" bin-path -c release --arch arm64)"
[ -x "${BIN_DIR}/ipadmode" ] || { echo "build-app: ${BIN_DIR}/ipadmode not found" >&2; exit 2; }

APP="${STAGE}/iPadMode.app"
mkdir -p "${APP}/Contents/MacOS"
cp "${BIN_DIR}/ipadmode" "${APP}/Contents/MacOS/ipadmode"
# Drop the debug map: it embeds the build path (/Volumes/SSD X/...), which must not appear in an installed file.
strip -S "${APP}/Contents/MacOS/ipadmode"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>local.ipadmode</string>
	<key>CFBundleName</key>
	<string>iPadMode</string>
	<key>CFBundleExecutable</key>
	<string>ipadmode</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST
plutil -lint "${APP}/Contents/Info.plist" >/dev/null
codesign --force --sign - --identifier local.ipadmode "${APP}"

# Escape for the replacement side of sed (| is the delimiter) and for an AppleScript string literal.
esc_sed() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
as_path="$(printf '%s' "${INSTALLED_CLI}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"

for entry in "${APPLETS[@]}"; do
  name="${entry%%:*}"; rest="${entry#*:}"; symbol="${rest%%:*}"; color="${rest##*:}"
  src="${STAGE}/${name}.applescript"
  sed -e "s|__IPADMODE_CLI__|$(esc_sed "${as_path}")|g" "${ROOT}/applets/${name}.applescript" > "${src}"
  echo "build-app: osacompile ${name}"
  osacompile -o "${STAGE}/${name}.app" "${src}"
  # Assets.car and CFBundleIconName take precedence over applet.icns, so remove them or the icon is ignored.
  rm -f "${STAGE}/${name}.app/Contents/Resources/Assets.car"
  plutil -remove CFBundleIconName "${STAGE}/${name}.app/Contents/Info.plist" 2>/dev/null || true
  iconset="${STAGE}/${name}.iconset"
  swift "${ROOT}/scripts/make-icons.swift" "${symbol}" "${iconset}" "${color}"
  iconutil -c icns -o "${STAGE}/${name}.app/Contents/Resources/applet.icns" "${iconset}"
  rm -rf "${iconset}"
  codesign --force --sign - "${STAGE}/${name}.app"
done

echo "build-app: done -> ${STAGE}"
