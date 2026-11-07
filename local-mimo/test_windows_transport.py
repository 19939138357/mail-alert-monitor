"""Verify Windows PowerShell's real bitmap/HTTP path using an isolated model fixture."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import threading

ROOT=Path(__file__).resolve().parents[1]
class Handler(BaseHTTPRequestHandler):
    status=200
    def log_message(self,*args):
        pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path=='/v1/chat/completions'
        assert self.headers['Authorization']=='Bearer '+('0'*64)
        assert body['messages'][1]['content'][0]['image_url']['url'].startswith('data:image/png;base64,')
        content=json.dumps({'lines':['示例邮件','确认码：063827']},ensure_ascii=False)
        response=json.dumps({'choices':[{'finish_reason':'stop','message':{'content':content}}]}).encode()
        self.send_response(Handler.status)
        self.send_header('Content-Type','application/json; charset=utf-8')
        if Handler.status==302:self.send_header('Location','http://127.0.0.1:48766/forbidden')
        self.send_header('Content-Length',str(len(response)))
        self.end_headers();self.wfile.write(response)


def main():
    if os.name!='nt':raise SystemExit('Run on Windows to verify Windows PowerShell and System.Drawing.')
    directory=ROOT/'legacy/windows/MiMo';directory.mkdir(exist_ok=True)
    secret=directory/'service.token'
    with secret.open('x') as stream:stream.write('0'*64)
    server=HTTPServer(('127.0.0.1',48765),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        source="""$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
. ./legacy/windows/MimoOCR.ps1
$bitmap=[Drawing.Bitmap]::new(160,90)
try { $text=@(Read-MimoText $bitmap);if ($text.Count -ne 2 -or $text[1] -cne '确认码：063827') {throw 'incorrect text'} }
finally {$bitmap.Dispose()}
"""
        for status in (200,302):
            Handler.status=status
            import base64
            encoded=base64.b64encode(source.encode('utf-16-le')).decode()
            result=subprocess.run(['powershell.exe','-NoProfile','-EncodedCommand',encoded],cwd=ROOT,capture_output=True,timeout=20)
            assert (result.returncode==0)==(status==200)
        print('PASS: Windows bitmap upload, authenticated loopback, exact Chinese/digits and redirect rejection.')
    finally:
        server.shutdown();server.server_close();thread.join(timeout=3);secret.unlink()

if __name__=='__main__':main()
