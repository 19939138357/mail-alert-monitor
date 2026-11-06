#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
delivery="$repo/dist"
cache="$repo/.build/phonepair"
mkdir -p "$cache" "$delivery"
stage="$(mktemp -d "$cache/bundle.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
name="手机配对.app"
app="$stage/$name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/bridge.py" "$here/short_code.py" "$app/Contents/Resources/"

cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.mailalertmonitor.phonepair</string>
<key>CFBundleName</key><string>手机配对</string>
<key>CFBundleExecutable</key><string>PhonePair</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>1.4.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSBonjourServices</key><array><string>_mailmonctl._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key><string>在所选网络广播配对服务，让安卓手机找到这台 Mac，并接收已配对手机的监控请求。</string>
<key>NSScreenCaptureUsageDescription</key><string>仅在配对手机请求时显示核对过的 Foxmail 邮箱区域。</string>
<key>NSAppleEventsUsageDescription</key><string>核对监控机邮箱窗口以响应配对手机请求。</string>
</dict></plist>
PLIST
for arch in arm64 x86_64; do
  flags=(-swift-version 5 -parse-as-library -O -target "${arch}-apple-macos14.0" -module-cache-path "$cache/swift-cache")
  xcrun swiftc "${flags[@]}" -file-prefix-map "$repo=." "$repo/macos/MailboxApproval.swift" "$repo/macos/Core.swift" "$repo/macos/Inbox.swift" "$here/Host.swift" "$here/MailboxFrame.swift" -o "$stage/host.$arch"
  xcrun swiftc "${flags[@]}" -file-prefix-map "$repo=." "$repo/macos/MailboxApproval.swift" "$here/PairingEvents.swift" "$here/PairingDiscovery.swift" "$here/PairingApp.swift" -o "$stage/pair.$arch"
done
xcrun lipo -create "$stage/host.arm64" "$stage/host.x86_64" -output "$app/Contents/Resources/MailControlHost"
xcrun lipo -create "$stage/pair.arm64" "$stage/pair.x86_64" -output "$app/Contents/MacOS/PhonePair"
codesign --force --sign - --identifier org.example.mailalertmonitor.phonehost "$app/Contents/Resources/MailControlHost"
"$app/Contents/Resources/MailControlHost" self-test
/usr/bin/codesign --force --sign - "$app" >/dev/null
/usr/bin/codesign --verify --strict "$app"
if [[ -e "$delivery/$name" ]]; then
  mv "$delivery/$name" "$stage/old.app"
fi
if ! mv "$app" "$delivery/$name"; then
  [[ ! -e "$stage/old.app" ]] || mv "$stage/old.app" "$delivery/$name"
  exit 1
fi
