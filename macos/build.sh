#!/bin/bash
set -euo pipefail
task_source="$(cd "$(dirname "$0")" && pwd)"
task_project="$(cd "$task_source/.." && pwd)"
task_app="${MAILMONITOR_BUILD_APP:-$task_project/dist/抽查邮件监控开源版.app}"
task_cache="$task_project/.build/swift-cache"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" "$task_cache"
xcrun swiftc -module-cache-path "$task_cache" "$task_source/GenerateSample.swift" -o "$task_cache/generate-sample"
"$task_cache/generate-sample" "$task_cache/MailSample.png"
cp "$task_cache/MailSample.png" "$task_app/Contents/Resources/MailSample.png"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$task_cache" \
  -target arm64-apple-macos14.0 "$task_source/Core.swift" "$task_source/NotificationHealth.swift" "$task_source/Inbox.swift" "$task_source/InboxScanner.swift" "$task_source/InboxTests.swift" "$task_source/SystemLogin.swift" "$task_source/RecoveryPolicy.swift" "$task_source/Recovery.swift" "$task_source/SafariDevice.swift" "$task_source/Interface.swift" "$task_source/App.swift" \
  -o "$task_app/Contents/MacOS/MailMonitor"
cp "$task_source/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_source/portal-login.js" "$task_app/Contents/Resources/portal-login.js"
cp "$task_source/portal-device.js" "$task_app/Contents/Resources/portal-device.js"
task_iconset="$task_cache/AppIcon.iconset"
mkdir -p "$task_iconset"
for task_size in 16 32 128 256 512; do
  sips -z "$task_size" "$task_size" "$task_source/Assets/AppIcon.png" --out "$task_iconset/icon_${task_size}x${task_size}.png" >/dev/null
  task_double=$((task_size * 2))
  sips -z "$task_double" "$task_double" "$task_source/Assets/AppIcon.png" --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
cp "$task_source/Assets/AppIcon.png" "$task_app/Contents/Resources/AppIcon.png"
codesign --force --sign - --identifier org.example.mailalertmonitor "$task_app"
"$task_app/Contents/MacOS/MailMonitor" --self-test
printf '%s\n' "$task_app"
