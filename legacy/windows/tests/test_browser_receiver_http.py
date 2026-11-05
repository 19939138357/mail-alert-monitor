"""Real loopback HTTP/DPAPI smoke test. Never sends mail or a webhook."""
import datetime, http.client, json, os, pathlib, socket, subprocess, time, uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / '04_资料' / '夜间告警升级_20260907' / 'http_test'
ARTIFACTS.mkdir(parents=True, exist_ok=True)
PS = str(pathlib.Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
child_env = os.environ.copy()
# PowerShell 7 parent module paths must not shadow Windows PowerShell 5.1 modules.
for key in list(child_env):
    if key.lower()=='psmodulepath':child_env.pop(key)
config = ARTIFACTS / 'synthetic_config.json'
config.write_text(json.dumps({'keywords':['告警抽查邮件'],'notificationSecretsFile':str(ARTIFACTS/'missing.xml')},ensure_ascii=False),encoding='utf-8')
with socket.socket() as probe:
    probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
command=[PS,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'BrowserKeywordReceiver.ps1'),'-ConfigPath',str(config),'-StateDirectory',str(ARTIFACTS),'-Port',str(port),'-NoSend']
process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW,env=child_env)
checks=0
def check(condition,label):
    global checks
    assert condition,label
    checks+=1
try:
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        if process.poll() is not None:
            raise RuntimeError(process.communicate()[1].decode(errors='replace'))
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=.2):break
        except OSError:time.sleep(.1)
    helper=ARTIFACTS/'read_test_token.ps1'
    helper.write_text(". '"+str(ROOT/'BrowserAlertSupport.ps1').replace("'","''")+"'\nGet-BrowserPairingToken '"+str(ARTIFACTS/'browser_pairing.xml').replace("'","''")+"'\n",encoding='utf-8-sig')
    token=subprocess.check_output([PS,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(helper)],creationflags=subprocess.CREATE_NO_WINDOW,env=child_env).decode().strip()
    check(len(token)==64,'DPAPI pairing token')
    def request(method,path,body=None,extra=None,authenticated=True):
        conn=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
        headers={'Content-Type':'application/json'}
        if authenticated:headers['X-Monitor-Token']=token
        if extra:headers.update(extra)
        conn.request(method,path,body=body,headers=headers)
        response=conn.getresponse();data=response.read();code=response.status;conn.close()
        return code,json.loads(data)
    code,data=request('GET','/status');check(code==200 and not data['configured'] and data['simulation'],'status reports unconfigured simulation')
    check(request('GET','/status',authenticated=False)[0]==401,'unauthenticated blocked')
    check(request('GET','/status',extra={'Origin':'https://malicious.example'})[0]==403,'web page origin blocked')
    check(request('GET','/trigger?keyword=x')[0]==404,'legacy unauthenticated GET trigger removed')
    body=json.dumps({'eventId':str(uuid.uuid4())+':1','keyword':'告警抽查邮件','createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat()},ensure_ascii=False).encode()
    code,data=request('POST','/trigger',body);check(code==200 and data['status']=='DryRun','valid authenticated event remains dry run')
    check(not (ARTIFACTS/'browser_events.json').exists(),'dry run does not consume event')
    check(request('POST','/trigger',b'x'*2049)[0]==400,'oversize payload blocked')
    # Force header and UTF-8 body across TCP reads.
    with socket.create_connection(('127.0.0.1',port),timeout=8) as stream:
        header=f'POST /trigger HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-Monitor-Token: {token}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n'.encode()
        stream.sendall(header[:40]);time.sleep(.03);stream.sendall(header[40:]);
        for offset in range(0,len(body),7):stream.sendall(body[offset:offset+7])
        chunks=[]
        while True:
            chunk=stream.recv(4096)
            if not chunk:break
            chunks.append(chunk)
        response=b''.join(chunks)
        check(response.startswith(b'HTTP/1.1 200') and b'DryRun' in response,'fragmented request and multibyte UTF8 accepted')
    check(request('POST','/stop',b'{}',authenticated=False)[0]==401,'unauthenticated stop blocked')
    code,data=request('POST','/stop',b'{}');check(code==200 and data['status']=='Stopped','authenticated stop accepted')
    process.wait(timeout=8);check(process.returncode==0,'receiver exits cleanly')
    print(f'PASS: {checks} real HTTP/DPAPI checks, zero external sends')
finally:
    process.terminate()
    try:process.communicate(timeout=8)
    except subprocess.TimeoutExpired:process.kill();process.communicate()
