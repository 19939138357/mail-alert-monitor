"""Exercise the compiled native client over loopback with synthetic responses."""
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

REPO=Path(__file__).resolve().parents[1]
APP=REPO/'dist/抽查邮件监控开源版.app/Contents/MacOS/MailMonitor'
IMAGE=REPO/'dist/抽查邮件监控开源版.app/Contents/Resources/MailSample.png'

class Fixture(BaseHTTPRequestHandler):
    reply=''
    status=200
    seen=0
    def log_message(self,*args):
        pass
    def do_POST(self):
        assert self.path=='/v1/chat/completions'
        assert self.headers['Authorization']=='Bearer '+('0'*64)
        request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert request['model']=='mimo-vl-local'
        png=request['messages'][1]['content'][0]['image_url']['url']
        assert base64.b64decode(png.split(',')[1]).startswith(b'\x89PNG\r\n')
        Fixture.seen+=1
        raw=Fixture.reply.encode()
        self.send_response(Fixture.status)
        self.send_header('Content-Type','application/json')
        if Fixture.status==302:
            self.send_header('Location','http://127.0.0.1:48766/private')
        self.send_header('Content-Length',str(len(raw)))
        self.end_headers();self.wfile.write(raw)


def response(text,finish='stop'):
    return json.dumps({'choices':[{'finish_reason':finish,'message':{'content':text}}]})


def main():
    with tempfile.TemporaryDirectory(dir=REPO/'.build',prefix='mimo-fixture-') as work:
        Path(work,'service.token').write_text('0'*64)
        server=HTTPServer(('127.0.0.1',48765),Fixture)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            env=dict(os.environ,MAIL_MIMO_HOME=work)
            cases=[(200,response('{"lines":["示例邮件","确认码：063827"]}'),True),
                   (302,'{}',False),(200,response('{"lines":["cut"]}','length'),False),
                   (200,response('{"lines":[]}'),False),(200,response('{"lines":[123]}'),False),
                   (200,response('{"lines":["a\\nb"]}'),False)]
            for status,body,success in cases:
                Fixture.status=status;Fixture.reply=body
                run=subprocess.run([APP,'--mimo-read',IMAGE],env=env,capture_output=True,text=True,timeout=15)
                assert (run.returncode==0)==success
                if success:assert run.stdout=='示例邮件\n确认码：063827\n'
            assert Fixture.seen==len(cases)
            print('PASS: 6 compiled native MiMo transport checks; loopback, local token, PNG, exact digits, redirects, truncated and invalid output.')
        finally:
            server.shutdown();server.server_close();thread.join(timeout=3)

if __name__=='__main__':
    main()
