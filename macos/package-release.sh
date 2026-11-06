#!/bin/bash
# Assemble both public apps from dist. Never copy the parent folder or user data.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/dist"
stage="$(mktemp -d "$repo/.build/release-mac.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
folder="$stage/MailAlertMonitor"
mkdir "$folder"
for app in 抽查邮件监控开源版.app 手机配对.app; do
  src="$out/$app"
  test -d "$src"
  codesign --verify --deep --strict "$src"
  ditto --norsrc --noqtn --noextattr "$src" "$folder/$app"
done
cp "$repo/LICENSE" "$folder/LICENSE.txt"
cp "$repo/macos/使用说明.txt" "$folder/使用说明.txt"
# Python sets the standard UTF-8 ZIP flag for Chinese app names and preserves
# Unix execute bits. Some extractors misread the legacy encoding of ditto -c.
python3 - "$folder" "$stage/package.zip" <<'PYZIP'
from pathlib import Path
import sys
from zipfile import ZipFile, ZIP_DEFLATED

folder = Path(sys.argv[1])
with ZipFile(sys.argv[2], "w", compression=ZIP_DEFLATED) as archive:
    for item in sorted(folder.rglob("*")):
        if item.is_symlink():
            raise SystemExit(f"Unexpected symbolic link in release: {item.name}")
        archive.write(item, item.relative_to(folder.parent))
PYZIP
unzip -tq "$stage/package.zip"
ditto -x -k "$stage/package.zip" "$stage/reopened"
for app in 抽查邮件监控开源版.app 手机配对.app; do
  codesign --verify --deep --strict "$stage/reopened/MailAlertMonitor/$app"
done
mv "$stage/package.zip" "$out/MailAlertMonitor-macOS.zip"
shasum -a 256 "$out/MailAlertMonitor-macOS.zip"
