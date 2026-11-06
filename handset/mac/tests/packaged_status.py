"""Exercise a built companion and monitor side-by-side; leave running monitors untouched."""
import hashlib
import http.client
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
from urllib.parse import parse_qs, urlsplit


def verify(apps):
    resources = apps / "手机配对.app/Contents/Resources"
    with tempfile.TemporaryDirectory(dir=apps) as private_dir:
        with subprocess.Popen([sys.executable, "-B", str(resources / "bridge.py"), "--bind", "127.0.0.1",
                               "--port", "0", "--apps", str(apps), "--private-dir", private_dir,
                               "--helper", str(resources / "MailControlHost")],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
            try:
                notice = json.loads(child.stdout.readline())
                fields = parse_qs(urlsplit(notice["url"]).query)
                endpoint = urlsplit(fields["url"][0])
                connection = http.client.HTTPSConnection(endpoint.hostname, endpoint.port,
                        context=ssl._create_unverified_context(), timeout=10)
                try:
                    connection.connect()
                    fingerprint = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
                    assert fingerprint == fields["pin"][0]
                    connection.request("GET", "/v1/status", headers={"Authorization": "Bearer " + fields["key"][0]})
                    response = connection.getresponse()
                    assert response.status == 200
                    assert {"running", "tickets", "pending", "uncertain", "monitorState"} <= json.loads(response.read()).keys()
                finally:
                    connection.close()
                child.stdin.close()
                assert child.wait(timeout=5) == 0
            finally:
                if child.poll() is None:
                    child.terminate()
    print("Packaged TLS listener, public monitor status, and pairing window shutdown passed.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve())
