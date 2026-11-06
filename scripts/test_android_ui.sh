#!/usr/bin/env bash
# Exercise the distributed APK in both themes on a disposable Android device.
set -euo pipefail
sdk="${ANDROID_HOME:?Android SDK required}"
out=".build/android-ui"
mkdir -p "$out"
if ! /usr/bin/python3 -c 'import PIL' 2>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends python3-pil
fi
manager="$sdk/cmdline-tools/latest/bin"
image='system-images;android-35;google_apis;x86_64'
"$manager/sdkmanager" 'platform-tools' 'emulator' "$image" >/dev/null
export ANDROID_USER_HOME="$PWD/$out/android-user"
export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | "$manager/avdmanager" create avd --force -n handset-release --path "$PWD/$out/handset.avd" --device pixel_2 -k "$image"
# avdmanager and emulator may resolve the runner's SDK user home differently.
# Register the absolute AVD directory in the directory both commands now share.
test -s "$out/handset.avd/config.ini"
printf 'avd.ini.encoding=UTF-8\npath=%s\ntarget=android-35\n' "$PWD/$out/handset.avd" > "$ANDROID_AVD_HOME/handset-release.ini"
"$sdk/emulator/emulator" -list-avds | grep -Fx handset-release
# Keep the disposable user partition within the GitHub runner disk budget.
printf "\ndisk.dataPartition.size=1024M\nhw.ramSize=2048\n" >> "$out/handset.avd/config.ini"
df -h .
sudo chgrp "$(id -gn)" /dev/kvm
sudo chmod g+rw /dev/kvm
"$sdk/emulator/emulator" -accel-check
"$sdk/emulator/emulator" -avd handset-release -no-window -no-audio -no-snapshot -no-boot-anim -gpu software -memory 2048 -cores 2 -partition-size 1024 -no-metrics -port 5554 >"$out/emulator.log" 2>&1 &
emulator_pid=$!
adb="$sdk/platform-tools/adb"
trap '"$adb" emu kill >/dev/null 2>&1 || true; kill "$emulator_pid" 2>/dev/null || true' EXIT
export ANDROID_SERIAL=emulator-5554
"$adb" start-server
ready=false
for attempt in $(seq 1 150); do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then tail -80 "$out/emulator.log"; exit 1; fi
    if [[ $(timeout 3 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; then ready=true; break; fi
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
    # The release uses FLAG_SECURE. Capture the disposable emulator display itself
    # only after checking the first-run pairing UI, with no credentials or mail.
    capture_dir="$(mktemp -d "$PWD/$out/display.XXXXXX")"
    "$adb" emu screenrecord screenshot "$capture_dir"
    shopt -s nullglob
    images=("$capture_dir"/*.png)
    if [[ ${#images[@]} != 1 ]]; then echo "Missing emulator display capture"; exit 1; fi
    destination="$out/pair-night-$theme.png"
    mv "${images[0]}" "$destination"
    rmdir "$capture_dir"
    /usr/bin/python3 - "$destination" <<'PYIMAGE'
from PIL import Image, ImageStat
import sys
with Image.open(sys.argv[1]) as image:
    width, height = image.size
    center = image.convert("RGB").crop((width // 10, height // 12, width * 9 // 10, height * 3 // 4))
    if width < 400 or height < 600 or max(ImageStat.Stat(center).stddev) < 12:
        raise SystemExit("Emulator capture is blank or incomplete")
PYIMAGE
done
