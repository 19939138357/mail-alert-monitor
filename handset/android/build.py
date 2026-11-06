#!/usr/bin/env python3
"""Compile, sign and verify the Android companion with JDK 17 and Android SDK 35."""
import fcntl
import hashlib
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from zipfile import ZipFile, ZIP_DEFLATED

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[1]
PACKAGE = 'cn.mailmonitor.handset'
ALIAS = 'handset-release'
DELIVERY = REPO / 'dist' / 'MailAlertMonitor-Android.apk'


def run(*args, capture=False):
    return subprocess.run([str(arg) for arg in args], check=True, cwd=SOURCE,
                          stdout=subprocess.PIPE if capture else None, text=True).stdout


def ensure_signing_key(jdk, directory):
    directory.mkdir(mode=0o700, exist_ok=True)
    secret = directory / 'password'
    keystore = directory / 'handset-release.p12'
    if keystore.exists() and not secret.is_file():
        raise SystemExit('Restore the existing signing password to keep the app upgradeable.')
    if not secret.exists():
        with secret.open('x') as target:
            target.write(secrets.token_hex(32) + '\n')
    if not keystore.exists():
        with tempfile.TemporaryDirectory(dir=directory) as work:
            pending = Path(work) / 'new.p12'
            run(jdk / 'bin/keytool', '-genkeypair', '-storetype', 'PKCS12',
                '-alias', ALIAS, '-keyalg', 'RSA', '-keysize', '3072',
                '-validity', '10000', '-keystore', pending, '-storepass:file', secret,
                '-dname', 'CN=Mail Monitor Handset', '-noprompt')
            pending.replace(keystore)
    return keystore, secret


def main():
    os.umask(0o077)
    if not os.environ.get('ANDROID_SDK_ROOT') or not os.environ.get('JAVA_HOME'):
        raise SystemExit('Set ANDROID_SDK_ROOT and JAVA_HOME before building.')
    sdk = Path(os.environ['ANDROID_SDK_ROOT'])
    buildtools = Path(os.environ.get('ANDROID_BUILD_TOOLS', sdk / 'build-tools/35.0.0'))
    jdk = Path(os.environ['JAVA_HOME'])
    android = sdk / 'platforms/android-35/android.jar'
    aapt = buildtools / 'aapt2'
    java = jdk / 'bin/java'
    for dependency in [android, aapt, java, buildtools / 'zipalign', buildtools / 'lib/apksigner.jar', buildtools / 'lib/d8.jar']:
        if not dependency.is_file():
            raise SystemExit('Missing required build dependency: ' + str(dependency))
    builds = SOURCE / '.build'
    builds.mkdir(exist_ok=True)
    with (builds / 'build.lock').open('a') as lock, tempfile.TemporaryDirectory(dir=builds) as work:
        fcntl.flock(lock, fcntl.LOCK_EX)
        tmp = Path(work)
        gen, classes, dex = (tmp / directory for directory in ('gen', 'classes', 'dex'))
        for directory in (gen, classes, dex):
            directory.mkdir()
        resources = tmp / 'resources.zip'
        unaligned = tmp / 'unaligned.apk'
        aligned = tmp / 'aligned.apk'
        signed = tmp / 'signed.apk'
        run(aapt, 'compile', '--dir', SOURCE / 'res', '-o', resources)
        run(aapt, 'link', '-I', android, '--manifest', SOURCE / 'AndroidManifest.xml',
            '--java', gen, '-o', unaligned, resources)
        sources = sorted((SOURCE / 'src').rglob('*.java')) + sorted(gen.rglob('*.java'))
        run(jdk / 'bin/javac', '-encoding', 'UTF-8', '-source', '8', '-target', '8',
            '-Xlint:-options', '-bootclasspath', os.pathsep.join(map(str, (android, buildtools / 'core-lambda-stubs.jar'))),
            '-d', classes, *sources)
        jar = tmp / 'classes.jar'
        run(jdk / 'bin/jar', '--create', '--file', jar, '-C', classes, '.')
        run(java, '-cp', buildtools / 'lib/d8.jar', 'com.android.tools.r8.D8', '--min-api', '26',
            '--lib', android, '--output', dex, jar)
        with ZipFile(unaligned, 'a', compression=ZIP_DEFLATED) as apk:
            apk.write(dex / 'classes.dex', 'classes.dex')
        run(buildtools / 'zipalign', '4', unaligned, aligned)
        signing_dir = Path(os.environ.get('MAIL_HANDSET_SIGNING_DIR', SOURCE / '.signing'))
        if 'MAIL_HANDSET_SIGNING_DIR' in os.environ and not all((signing_dir / f).is_file() for f in ('password', 'handset-release.p12')):
            raise SystemExit('Explicit signing directory is incomplete.')
        keystore, secret = ensure_signing_key(jdk, signing_dir)
        signer = buildtools / 'lib/apksigner.jar'
        run(java, '-jar', signer, 'sign', '--ks', keystore, '--ks-key-alias', ALIAS,
            '--ks-pass', 'file:' + str(secret), '--v4-signing-enabled', 'false', '--out', signed, aligned)
        run(java, '-jar', signer, 'verify', '--verbose', '--print-certs', signed)
        run(buildtools / 'zipalign', '-c', '4', signed)
        badging = run(aapt, 'dump', 'badging', signed, capture=True)
        required = ["package: name='" + PACKAGE + "'", "minSdkVersion:'26'", "targetSdkVersion:'35'",
                    "uses-permission: name='android.permission.INTERNET'", "launchable-activity: name='" + PACKAGE + "."]
        for entry in required:
            if entry not in badging:
                raise SystemExit('Missing expected APK metadata: ' + entry)
        for line in badging.splitlines():
            if line.startswith(('package:', 'application-label:', 'launchable-activity:', 'minSdkVersion:', 'targetSdkVersion:')):
                print(line)
        DELIVERY.parent.mkdir(parents=True, exist_ok=True)
        signed.replace(DELIVERY)
        DELIVERY.chmod(0o644)
        print(f'{DELIVERY}\n{DELIVERY.stat().st_size} bytes · SHA-256 {hashlib.sha256(DELIVERY.read_bytes()).hexdigest()}')


if __name__ == '__main__':
    main()
