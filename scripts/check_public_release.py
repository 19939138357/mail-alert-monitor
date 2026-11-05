#!/usr/bin/env python3
"""Check the tracked source snapshot without opening runtime data or secrets."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
paths = [ROOT / name for name in tracked if name]
if not paths:
    raise SystemExit('FAIL: stage the explicit source snapshot before checking')
errors = []
blocked_parts = {'.git', 'node_modules', '.venv', '__pycache__', 'signing', 'runtime', '04_资料', '.build', 'dist', 'build', 'bin', 'obj'}
blocked_suffixes = {'.log', '.apk', '.exe', '.dll', '.keystore', '.jks', '.pem', '.key', '.zip', '.pyc', '.class'}
blocked_names = {'monitor_config.json', 'notification_settings.json', 'notification_secrets.xml', 'settings.json', 'last_ocr.txt', 'last_screenshot.png', '.DS_Store'}
patterns = {
    'private-key': re.compile(r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'),
    'github-token': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'personal-path': re.compile(r'(?:/' + r'Users/[^/\s]+/|[A-Z]:\\Users\\[^\\\s]+\\)'),
    'private-IP': re.compile(r'(?<![0-9])(?:10(?:\.[0-9]{1,3}){3}|192\.168(?:\.[0-9]{1,3}){2}|172\.(?:1[6-9]|2[0-9]|3[01])(?:\.[0-9]{1,3}){2})(?![0-9])'),
    'production-domain': re.compile(r'(?:highway|highway-noc|highway-moc)\s*(?:\\\\)?\.'),
}
for path in paths:
    rel = path.relative_to(ROOT)
    if path.is_symlink(): errors.append(f'{rel}: symbolic link is not allowed'); continue
    if any(part in blocked_parts for part in rel.parts) or path.suffix.lower() in blocked_suffixes or path.name in blocked_names or (path.name.startswith('.env') and path.name != '.env.example'):
        errors.append(f'{rel}: excluded runtime/build/secret path')
    if path.stat().st_size > 10_000_000: errors.append(f'{rel}: larger than 10 MB')
    try: body = path.read_text(encoding='utf-8-sig')
    except UnicodeDecodeError:
        if path.suffix.lower() not in {'.png', '.ico', '.wav'}: errors.append(f'{rel}: unexpected binary file')
        continue
    for label, pattern in patterns.items():
        for match in pattern.finditer(body):
            # Report only location and category, never the matched value.
            line = body.count('\n', 0, match.start()) + 1
            errors.append(f'{rel}:{line}: {label}')
if errors:
    print('\n'.join('FAIL: ' + error for error in errors))
    sys.exit(1)
print(f'PASS: {len(paths)} tracked files; excluded paths, large files and credential patterns checked')
