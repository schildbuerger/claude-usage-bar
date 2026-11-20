#!/bin/zsh
# Builds ClaudeUsageBar.app next to this script.
set -e
cd "$(dirname "$0")"
APP=ClaudeUsageBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/ClaudeUsageBar" main.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.claude-usage-bar</string>
  <key>CFBundleName</key><string>ClaudeUsageBar</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
xattr -cr "$APP"
codesign --force -s - "$APP"
echo "Built $(pwd)/$APP"
