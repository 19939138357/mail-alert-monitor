#!/usr/bin/env python3
"""Install checksum-pinned public weights and run a loopback-only MiMo server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import socket
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit
from zipfile import ZipFile

HERE = Path(__file__).resolve().parent


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def fetch(item, folder):
    target = folder / item['name']
    if target.is_file() and target.stat().st_size == item['size'] and digest(target) == item['sha256']:
        return target
    partial = target.with_suffix(target.suffix + '.partial')
    if partial.is_file() and partial.stat().st_size >= item['size']:
        if partial.stat().st_size == item['size'] and digest(partial) == item['sha256']:
            os.replace(partial, target)
            return target
        partial.unlink()
    urls = [item['url']]
    if urlsplit(item['url']).hostname == 'huggingface.co':
        urls.append(item['url'].replace('https://huggingface.co/', 'https://hf-mirror.com/', 1))
    for attempt in range(4):
        for url in urls:
            print('下载 ' + item['name'] + '，中断后可再次打开继续。', flush=True)
            command = ['curl', '--fail', '--location', '--show-error', '--connect-timeout', '15',
                       '--speed-limit', '1024', '--speed-time', '60', '--retry', '2', '--continue-at', '-',
                       '--output', str(partial), url]
            if subprocess.run(command).returncode:
                continue
            if partial.stat().st_size == item['size'] and digest(partial) == item['sha256']:
                os.replace(partial, target)
                return target
            partial.unlink(missing_ok=True)
            print('下载校验未通过，正在重新获取。', flush=True)
        time.sleep(2)
    raise RuntimeError('模型下载尚未完成，请检查网络后重新打开。已下载的部分会保留。')


def unpack(archive, destination):
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        root = Path(temporary).resolve()
        if archive.name.endswith('.zip'):
            with ZipFile(archive) as data:
                members = data.namelist()
                for name in members:
                    path = (root / name).resolve()
                    if root not in path.parents:
                        raise ValueError('Unexpected archive path')
                data.extractall(root)
        else:
            with tarfile.open(archive) as data:
                for item in data.getmembers():
                    path = (root / item.name).resolve()
                    if root not in path.parents:
                        raise ValueError('Unexpected archive path')
                    if item.issym() or item.islnk():
                        link = (path.parent / item.linkname).resolve()
                        if root not in link.parents:
                            raise ValueError('Unexpected archive link')
                data.extractall(root)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(root, destination, symlinks=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_home = Path.home() / 'Library/Application Support/MailAlertMonitorOpenSource/mimo'
    parser.add_argument('--home', type=Path, default=default_home)
    parser.add_argument('--download-only', action='store_true')
    args = parser.parse_args()
    manifest = json.loads((HERE / 'model.json').read_text())
    key = ('mac-arm64' if platform.machine() == 'arm64' else 'mac-x64') if sys.platform == 'darwin' else 'windows-x64'
    home = args.home.expanduser().resolve()
    os.umask(0o077)
    home.mkdir(parents=True, exist_ok=True)
    # A held OS file lock excludes duplicate installers and model processes.
    with (home / 'instance.lock').open('a+b') as lock:
        if os.name == 'nt':
            import msvcrt
            lock.write(b'0'); lock.flush(); lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('小米 MiMo 本地模型。首次下载约 5.4 GB，建议 16 GB 或更多内存。', flush=True)
        print('位置 ' + str(home), flush=True)
        package = fetch(manifest['runtime'][key], home)
        runtime = home / 'runtime'
        stamp = runtime / '.archive-sha256'
        expected = manifest['runtime'][key]['sha256']
        if not stamp.is_file() or stamp.read_text() != expected:
            unpack(package, runtime)
            stamp.write_text(expected)
        files = [fetch(item, home) for item in manifest['files']]
        if args.download_only:
            print('模型及运行程序下载校验通过。', flush=True)
            return
        name = 'llama-server.exe' if os.name == 'nt' else 'llama-server'
        binaries = list(runtime.rglob(name))
        if len(binaries) != 1:
            raise RuntimeError('模型运行程序不完整，请移除 runtime 文件夹后重新打开。')
        binary = binaries[0]
        token_file = home / 'service.token'
        if not token_file.exists():
            with token_file.open('x') as stream:
                stream.write(secrets.token_hex(32))
        token = token_file.read_text().strip()
        if len(token) != 64 or any(c not in '0123456789abcdef' for c in token):
            raise RuntimeError('本机模型连接凭据无效，请移除 service.token 后重试。')
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', manifest['port']))
        command = [str(binary), '--model', str(files[0]), '--mmproj', str(files[1]),
                   '--api-key', token, '--alias', manifest['alias'], '--host', '127.0.0.1', '--port', str(manifest['port']),
                   '--jinja', '--reasoning-budget', '0', '--ctx-size', '8192', '--parallel', '1', '--batch-size', '256', '--ubatch-size', '128',
                   '--threads', '4', '--n-gpu-layers', '99' if key == 'mac-arm64' else '0', '--log-disable']
        print('正在加载，显示就绪后请回到邮件监控。关闭本窗口会停止小米模型。', flush=True)
        with subprocess.Popen(command, cwd=binary.parent) as process:
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                for attempt in range(180):
                    if process.poll() is not None:
                        raise RuntimeError('模型程序已退出，请检查可用内存。')
                    try:
                        with opener.open('http://127.0.0.1:48765/health', timeout=2) as response:
                            if response.status == 200:
                                print('小米模型已就绪。回到监控设置选择“小米 MiMo 本地”。', flush=True)
                                break
                    except OSError:
                        pass
                    time.sleep(1)
                else:
                    raise RuntimeError('模型加载超时，请检查内存并重新打开。')
                process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
