#!/usr/bin/env python3
"""Scan the exact Git index snapshot used to construct the public commit."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


# Protocol network ranges and synthetic LAN test inputs. Each exception is exact
# and confined to the file that exercises the address parser or discovery code.
def addresses(*octets):
    return {'.'.join(str(n) for n in address) for address in octets}


lan_fixtures = {
    'handset/mac/bridge.py': addresses((10, 0, 0, 0), (172, 16, 0, 0), (192, 168, 0, 0)),
    'handset/mac/test_bridge.py': addresses((192, 168, 1, 1)),
    'handset/mac/tests/PairingEventsTest.swift': addresses((192, 168, 1, 25)),
    'handset/android/tests/LocalComputerTest.java': addresses(
        (10, 0, 0, 1), (192, 168, 1, 25), (172, 16, 0, 1), (172, 31, 255, 254),
        (192, 168, '01', 2), (192, 168, 3, 4)),
    'handset/android/tests/PairingTest.java': addresses((192, 168, 20, 8)),
}

blocked_parts = {'.git', 'node_modules', '.venv', '__pycache__', 'signing', '.signing', 'runtime', '04_资料', '.build', 'dist', 'build', 'bin', 'obj'}
blocked_suffixes = {'.log', '.apk', '.exe', '.dll', '.keystore', '.jks', '.pem', '.key', '.p12', '.pfx', '.token', '.zip', '.pyc', '.class'}
blocked_names = {'password', 'pair.key', 'monitor_config.json', 'notification_settings.json', 'notification_secrets.xml', 'settings.json', 'last_ocr.txt', 'last_screenshot.png', '.DS_Store'}
patterns = {
    'private-key': re.compile(r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'),
    'github-token': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'personal-path': re.compile(r'(?:/' + r'Users/[^/\s]+/|[A-Z]:\\Users\\[^\\\s]+\\)'),
    'private-IP': re.compile(r'(?<![0-9])(?:10(?:\.[0-9]{1,3}){3}|192\.168(?:\.[0-9]{1,3}){2}|172\.(?:1[6-9]|2[0-9]|3[01])(?:\.[0-9]{1,3}){2})(?![0-9])'),
    'production-domain': re.compile(r'(?:highway|highway-noc|highway-moc)\s*(?:\\\\)?\.'),
}
entries = git('ls-files', '--stage', '-z').decode().rstrip('\0').split('\0')
if not entries[0]:
    raise SystemExit('FAIL: no files staged for checking')
errors = []
for entry in entries:
    meta, name = entry.split('\t', 1)
    mode, sha, stage = meta.split()
    path = pathlib.PurePosixPath(name)
    if stage != '0' or mode not in {'100644', '100755'}:
        errors.append(f'{name}: unresolved or unsupported file type')
        continue
    if (set(path.parts) & blocked_parts or path.suffix.lower() in blocked_suffixes or
            path.name in blocked_names or (path.name.startswith('.env') and path.name != '.env.example')):
        errors.append(f'{name}: excluded runtime/build/secret path')
        continue
    if int(git('cat-file', '-s', sha)) > 10_000_000:
        errors.append(f'{name}: larger than 10 MB')
        continue
    raw = git('cat-file', 'blob', sha)
    try:
        body = raw.decode('utf-8-sig')
    except UnicodeDecodeError:
        if path.suffix.lower() not in {'.png', '.ico', '.wav'}:
            errors.append(f'{name}: unexpected binary file')
        continue
    for label, pattern in patterns.items():
        for match in pattern.finditer(body):
            if label == 'private-IP' and match.group() in lan_fixtures.get(name, ()):
                continue
            line = body.count('\n', 0, match.start()) + 1
            errors.append(f'{name}:{line}: {label}')
if errors:
    print('\n'.join('FAIL: ' + error for error in errors))
    sys.exit(1)
print(f'PASS: {len(entries)} Git index entries checked')
