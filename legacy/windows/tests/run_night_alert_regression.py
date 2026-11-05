"""Run notification/browser regression without external delivery or real credentials."""
import os, pathlib, shutil, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
output=ROOT/'04_资料'/('微信通知升级_20260907' if '--wechat' in sys.argv else '夜间告警升级_20260907')/'集中回归结果.txt'
output.parent.mkdir(parents=True, exist_ok=True)
env=os.environ.copy()
for key in list(env):
    if key.lower()=='psmodulepath':env.pop(key)
env['PYTHONIOENCODING']='utf-8'
ps=str(pathlib.Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
node=shutil.which('node.exe')
jobs=[]
if '--wechat' in sys.argv:
    jobs.append(('Test-WeChatNotification.ps1',[ps,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'tests'/'Test-WeChatNotification.ps1')]))
for name in ['Test-NotificationTransport.ps1','Test-NightAlarm.ps1','Test-NotificationSettings.ps1','Test-NotificationPersistence.ps1','Test-VerificationPush.ps1','Test-MonitorIntegration.ps1','Test-BrowserAlertReceiver.ps1','Test-BrowserSetupUi.ps1']:
    jobs.append((name,[ps,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'tests'/name)]))
for name in ['Test-BrowserAlertCore.js','Test-BrowserExtensionLifecycle.js','Test-BrowserContentLifecycle.js']:
    jobs.append((name,[node,str(ROOT/'tests'/name)]))
jobs.append(('test_browser_receiver_http.py',[sys.executable,str(ROOT/'tests'/'test_browser_receiver_http.py')]))
results=[]
for name,command in jobs:
    result=subprocess.run(command,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
    text=result.stdout.decode('utf-8',errors='replace').strip()
    results.append(f'[{name}] exit={result.returncode}\n{text}\n')
    print(results[-1],flush=True)
    output.write_text('\n'.join(results),encoding='utf-8')
    if result.returncode:raise SystemExit(result.returncode)
print(f'PASS: {len(jobs)} suites; no external delivery')
