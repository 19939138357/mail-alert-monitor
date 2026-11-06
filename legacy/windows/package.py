"""Build the public Windows portable ZIP from its reviewed source inputs."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
import urllib.request
from zipfile import ZipFile, ZIP_DEFLATED

WINDOWS = Path(__file__).resolve().parent
ROOT = WINDOWS.parents[1]
DESKTOP = WINDOWS / '03_交付物/告警抽查桌面版'
WORK = ROOT / '.build/windows-package'
SCRIPTS = (
    'Monitor-WindowKeywords.ps1', 'FoxmailQueue.ps1', 'FoxmailScreen.ps1', 'FoxmailScreenNative.cs',
    'MailConfirmation.ps1', 'VerificationCode.ps1',
    'VerificationMonitor.ps1', 'VerificationPush.ps1', 'NotificationTransport.ps1',
    'Configure-PhoneNotification.ps1', 'Test-VerificationPhone.ps1',
    'paddle_ocr_runner.py', 'monitor_config.example.json', '03_交付物/微信通知使用说明.md',
)
REFERENCES = (
    'mscorlib', 'System', 'System.Core', 'System.Windows.Forms', 'System.Drawing',
    'System.Management', 'System.Web.Extensions', 'System.Security',
)


def checked(data, checksum, name):
    if sha256(data).hexdigest().lower() != checksum.lower():
        raise ValueError('Unexpected checksum for ' + name)
    return data


def dependency(lock):
    pkg = WORK / 'antdui.nupkg'
    if not pkg.exists():
        url = ('https://api.nuget.org/v3-flatcontainer/antdui/{0}/antdui.{0}.nupkg'
               .format(lock['Version']))
        with urllib.request.urlopen(url, timeout=60) as response:
            data = checked(response.read(), lock['PackageSha256'], 'AntdUI package')
        pkg.write_bytes(data)
    checked(pkg.read_bytes(), lock['PackageSha256'], 'AntdUI package')
    with ZipFile(pkg) as archive:
        dll = checked(archive.read('lib/net48/AntdUI.dll'), lock['DllSha256'], 'AntdUI.dll')
    target = WORK / 'AntdUI.dll'
    target.write_bytes(dll)
    return target


def compile_app(args, dll):
    if args.dotnet and args.roslyn and args.framework:
        compiler = [str(args.dotnet.absolute()), str(args.roslyn.absolute()), '/nostdlib+']
        refs = [str((args.framework / (name + '.dll')).absolute()) for name in REFERENCES]
    elif os.name == 'nt' and not any((args.dotnet, args.roslyn, args.framework)):
        fx = Path(os.environ['WINDIR']) / 'Microsoft.NET'
        csc = next((p for p in (fx / arch / 'v4.0.30319/csc.exe' for arch in ('Framework64', 'Framework')) if p.is_file()), None)
        if csc is None:
            raise RuntimeError('Install .NET Framework 4.8 first.')
        compiler = [str(csc)]
        refs = [name + '.dll' for name in REFERENCES if name != 'mscorlib']
    else:
        raise RuntimeError('Use the system compiler on Windows, or specify all three cross-compiler paths.')
    target = WORK / 'MailAlertMonitor.exe'
    cmd = compiler + ['/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
                      '/codepage:65001', '/out:' + str(target),
                      '/win32icon:' + str(DESKTOP / 'assets/screen-alert.ico')]
    cmd += ['/reference:' + ref for ref in refs + [str(dll)]]
    cmd += [str(DESKTOP / (name + '.cs')) for name in (
        'AlertSpotCheckDesktop', 'DesktopTheme', 'MonitorSettings', 'MailRegions', 'UnreadReview', 'EdgeSystemLogin')]
    subprocess.run(cmd, check=True)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('dotnet', 'roslyn', 'framework'):
        parser.add_argument('--' + option, type=Path)
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    dll = dependency(json.loads((DESKTOP / 'dependencies.lock.json').read_text(encoding='utf-8')))
    exe = compile_app(args, dll)
    inputs = {name: WINDOWS / name for name in SCRIPTS}
    for name in ('screen-alert.ico', 'screen-alert-256.png'):
        inputs['assets/' + name] = DESKTOP / 'assets' / name
    inputs.update({'MailAlertMonitor.exe': exe, 'AntdUI.dll': dll,
                   'LICENSE.txt': ROOT / 'LICENSE', 'AntdUI-LICENSE.txt': DESKTOP / 'AntdUI-LICENSE.txt',
                   '使用说明.txt': WINDOWS / 'PORTABLE.md'})
    destination = ROOT / 'dist/MailAlertMonitor-Windows.zip'
    destination.parent.mkdir(exist_ok=True)
    stage = WORK / 'windows-release.tmp'
    with ZipFile(stage, 'w', compression=ZIP_DEFLATED) as archive:
        for name, source in sorted(inputs.items()):
            archive.write(source, 'MailAlertMonitor/' + name)
    with ZipFile(stage) as archive:
        if archive.testzip() or len(archive.namelist()) != len(inputs):
            raise ValueError('Invalid archive')
        for name, source in inputs.items():
            if archive.read('MailAlertMonitor/' + name) != source.read_bytes():
                raise ValueError('Wrong archive contents: ' + name)
    os.replace(stage, destination)
    print(destination)


if __name__ == '__main__':
    main()
