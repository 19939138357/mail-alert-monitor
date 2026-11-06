#!/usr/bin/env bash
# Exercise the distributed APK in both themes on a disposable Android device.
set -euo pipefail
sdk="${ANDROID_HOME:?Android SDK required}"
out=".build/android-ui"
mkdir -p "$out"
manager="$sdk/cmdline-tools/latest/bin"
image='system-images;android-35;google_apis;x86_64'
"$manager/sdkmanager" 'platform-tools' 'emulator' "$image" >/dev/null
echo no | "$manager/avdmanager" create avd --force -n handset-release -k "$image"
sudo chmod 666 /dev/kvm
"$sdk/emulator/emulator" -avd handset-release -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect >"$out/emulator.log" 2>&1 &
emulator_pid=$!
adb="$sdk/platform-tools/adb"
trap '"$adb" emu kill >/dev/null 2>&1 || true; kill "$emulator_pid" 2>/dev/null || true' EXIT
timeout 120 "$adb" wait-for-device
ready=false
for attempt in $(seq 1 100); do
    if [[ $("$adb" shell getprop sys.boot_completed | tr -d '\r') == 1 ]]; then ready=true; break; fi
    sleep 2
done
if [[ "$ready" != true ]]; then tail -30 "$out/emulator.log"; exit 1; fi
"$adb" shell input keyevent KEYCODE_WAKEUP
"$adb" shell wm dismiss-keyguard
"$adb" install -r dist/MailAlertMonitor-Android.apk
for theme in no yes; do
    "$adb" shell cmd uimode night "$theme"
    "$adb" shell am force-stop cn.mailmonitor.handset
    "$adb" shell am start -W -n cn.mailmonitor.handset/.MainActivity
    sleep 2
    "$adb" shell uiautomator dump /sdcard/window.xml >/dev/null
    "$adb" exec-out cat /sdcard/window.xml > "$out/window.xml"
    python3 - "$out/window.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
nodes = [n for n in ET.parse(sys.argv[1]).iter('node') if n.get('package') == 'cn.mailmonitor.handset']
labels = {n.get('text') for n in nodes}
if not {'配对电脑', '配对并连接'} <= labels or not any(n.get('class') == 'android.widget.EditText' for n in nodes):
    raise SystemExit('Missing pairing title, code field, or connect action')
PY
    "$adb" exec-out screencap -p > "$out/pair-night-$theme.png"
done
