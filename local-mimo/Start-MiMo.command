#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if command -v python3 >/dev/null 2>&1; then
  exec python3 install.py
fi
printf '%s\n' '请先安装 Python 3.8 或更高版本，再打开本工具。' 'https://www.python.org/downloads/macos/'
read -r -p '按回车关闭。'
