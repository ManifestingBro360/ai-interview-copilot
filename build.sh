#!/bin/bash
# Builds InterviewCopilot.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="InterviewCopilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/InterviewCopilot "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.interviewcopilot</string>
<key>CFBundleName</key><string>InterviewCopilot</string>
<key>CFBundleExecutable</key><string>InterviewCopilot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Hears your side of the conversation so follow-up questions make sense.</string>
</dict></plist>
PLIST
# Signed with the Apple Development certificate so macOS remembers the recording permissions across rebuilds.
codesign --force --sign "Apple Development" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
echo "Built $APP"
