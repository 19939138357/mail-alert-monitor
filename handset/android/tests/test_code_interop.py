"""Run against a temporary private-IP TLS server; requires a JVM and org.json test JAR."""
import argparse
import contextlib
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlencode

sys.dont_write_bytecode = True
MOBILE = Path(__file__).resolve().parents[2]
REPO = MOBILE.parent
sys.path.insert(0, str(MOBILE / "mac"))
import bridge
from short_code import ShortCodeOffer


def run(ip, jdk, jar, scratch):
    source = MOBILE / "android/src/cn/mailmonitor/handset"
    tests = MOBILE / "android/tests"
    with tempfile.TemporaryDirectory(dir=scratch) as temp:
        workspace = Path(temp)
        classes = workspace / "classes"
        classes.mkdir()
        subprocess.run([jdk / "javac", "-cp", jar, "-encoding", "UTF-8", "-d", classes,
                        source / "CodeExchange.java", source / "Pairing.java",
                        source / "LocalComputer.java", tests / "CodePairProbe.java"], check=True)

        @contextlib.contextmanager
        def listening(cert_addr=None):
            certificate, key, pin = bridge.identity(workspace, cert_addr or ip)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(certificate, key)
            bearer = secrets.token_urlsafe(32)
            status_reads = []
            def native(*cmd):
                assert cmd == ("status",)
                status_reads.append(1)
                return {"running": False, "tickets": [], "monitorState": "fixture"}
            with bridge.PrivateServer((ip,0), ctx, bearer, native) as server:
                port = server.server_address[1]
                server.offer = ShortCodeOffer(pin, "000043")
                server.pairing_url = "mailmonitor://pair?" + urlencode({
                    "url": "https://%s:%s" % (ip, port), "pin": pin, "key": bearer})
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval":0.05})
                thread.start()
                try:
                    def try_code(code, expected):
                        cp = os.pathsep.join((str(classes), str(jar)))
                        probe = subprocess.run([jdk / "java", "-cp", cp, "cn.mailmonitor.handset.CodePairProbe",
                                                ip, str(port)], input=code+"\n", text=True, capture_output=True, timeout=20)
                        assert probe.returncode == expected, (probe.stdout, probe.stderr)
                    yield server, try_code, status_reads
                finally:
                    server.shutdown()
                    thread.join()

        with listening() as (s, attempt, reads):
            attempt("000044",1)
            attempt("000043",0)
            attempt("000043",1)
            assert len(reads) == 1
        with listening() as (s, attempt, reads):
            finish = s.offer.finish
            def forged_proof(data):
                result = finish(data)
                result["proof"] = "00"*32
                return result
            s.offer.finish = forged_proof
            attempt("000043",1)
            assert reads == []
        with listening() as (s, attempt, reads):
            s.pairing_url = s.pairing_url.replace("pin=", "pin="+"00"*32)
            attempt("000043",1)
            assert reads == []
        with listening("127.0.0.1") as (s, attempt, reads):
            attempt("000043",1)
            assert reads == [] and s.offer._count == 0

        print("Verified numeric pairing over TLS: wrong code, leading zero, single use, server proof, link binding, IP SAN.")


if __name__ == "__main__":
    arg = argparse.ArgumentParser()
    arg.add_argument("ip", help="An available local private IPv4 address, e.g. the Mac Wi-Fi IP")
    arg.add_argument("--jdk-bin", type=Path, required=True)
    scratch = REPO / ".build" / "pair-test"
    scratch.mkdir(parents=True, exist_ok=True)
    arg.add_argument("--json-jar", type=Path, required=True, help="org.json:json:20240303 (JVM tests only)")
    args = arg.parse_args()
    run(args.ip, args.jdk_bin, args.json_jar, scratch)
