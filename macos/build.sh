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
sources=(Core NotificationHealth Inbox InboxScanner InboxTests SystemLogin RecoveryPolicy Recovery SafariDevice MailboxApproval PublicMailbox Interface App)
swift_files=()
for source in "${sources[@]}"; do swift_files+=("$task_source/$source.swift"); done
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$task_cache" \
    -file-prefix-map "$task_project=." -target "$arch-apple-macos14.0" "${swift_files[@]}" \
    -o "$task_cache/MailMonitor-$arch"
  strip -S "$task_cache/MailMonitor-$arch"
done
xcrun lipo -create "$task_cache/MailMonitor-arm64" "$task_cache/MailMonitor-x86_64" \
  -output "$task_app/Contents/MacOS/MailMonitor"
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
