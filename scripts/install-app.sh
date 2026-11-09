#!/bin/sh
# Builds ~/Applications/SeekPop.app, a launcher that opens the SeekPop palette through Hammerspoon.
# Run it again after pulling changes; it overwrites the files it owns.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
app="$HOME/Applications/SeekPop.app"
contents="$app/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>SeekPop</string>
	<key>CFBundleDisplayName</key><string>SeekPop</string>
	<key>CFBundleIdentifier</key><string>io.github.duarbdhks.seekpop</string>
	<key>CFBundleExecutable</key><string>SeekPop</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cat > "$contents/MacOS/SeekPop" <<'LAUNCHER'
#!/bin/sh
# Hammerspoon handles hammerspoon:// URLs only after its config has loaded.
# shortcut: a cold start waits a fixed 2 s; poll for the config if a first open is ever missed.
if ! pgrep -xq Hammerspoon; then
	open -a Hammerspoon
	sleep 2
fi
open "hammerspoon://seekpop"
LAUNCHER
chmod +x "$contents/MacOS/SeekPop"

icon="$repo/app/AppIcon.png"
if [ -f "$icon" ]; then
	iconset="$(mktemp -d)/AppIcon.iconset"
	mkdir -p "$iconset"
	for size in 16 32 128 256 512; do
		sips -z "$size" "$size" "$icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
		sips -z "$((size * 2))" "$((size * 2))" "$icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
	done
	iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
fi

touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app"

