"""Private HTTPS transport between one Android client and the local monitor adapter."""
import argparse
import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import select
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlencode
from short_code import ShortCodeError, ShortCodeOffer

PORT = 48763
PAIR_ROUTES = {"/v1/pair/start", "/v1/pair/finish"}
PRIVATE_NETWORKS = tuple(map(ipaddress.ip_network, ("10.0.0.0/8", "172.16.0.0/12",
                                                  "192.168.0.0/16", "100.64.0.0/10")))


def private_address(value):
    ip = ipaddress.IPv4Address(value)
    if not (ip.is_loopback or any(ip in net for net in PRIVATE_NETWORKS)):
        raise ValueError("请选择 Mac 的局域网或私人 VPN 地址")
    return str(ip)


def identity(root, address):
    # Per-address identity keeps hostname validation intact on both LAN and VPN.
    directory = root / address
    directory.mkdir(mode=0o700, exist_ok=True)
    cert, key = directory / "host.pem", directory / "host.key"
    if not (cert.exists() and key.exists()):
        with tempfile.TemporaryDirectory(dir=directory) as scratch:
            folder = Path(scratch)
            config = folder / "cert.cnf"
            config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                              "[dn]\nCN=Mail Monitor\n[ext]\nsubjectAltName=IP:" + address +
                              "\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
            subprocess.run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                            "-x509", "-sha256", "-days", "730", "-config", str(config),
                            "-keyout", str(folder / "key"), "-out", str(folder / "cert")],
                           check=True, capture_output=True, timeout=20)
            os.replace(folder / "key", key)
            os.replace(folder / "cert", cert)
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    return cert, key, pin


def pairing_key(root, rotate=False):
    path = root / "pair.key"
    if rotate or not path.exists():
        token = secrets.token_urlsafe(32)
        with tempfile.NamedTemporaryFile(dir=root, mode="w", delete=False) as f:
            f.write(token)
            f.flush()
            os.fsync(f.fileno())
        os.replace(f.name, path)
    key = path.read_text()
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", key):
        raise ValueError("配对密钥损坏，请停止并重设配对")
    return key


class BridgeError(Exception):
    def __init__(self, status, message):
        self.status = status
        self.message = message


class NativeMonitor:
    def __init__(self, helper, apps):
        self.helper = str(helper)
        self.env = dict(os.environ, MAIL_MONITOR_APPS=str(apps))

    def __call__(self, *args):
        try:
            proc = subprocess.run([self.helper, *args], env=self.env, stdin=subprocess.DEVNULL,
                                  capture_output=True, timeout=20, check=False)
            obj = json.loads(proc.stdout)
            if not isinstance(obj, dict):
                raise ValueError()
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise BridgeError(503, "电脑端未能及时响应，请检查 Mac 配对窗口后刷新")
        if proc.returncode or "error" in obj:
            raise BridgeError(409, str(obj.get("error") or "操作未完成，请刷新后重试")[:480])
        return obj


class MonitorAPI(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "MailMonitor"
    sys_version = ""

    def log_message(self, *args):
        pass  # No URLs, pairing secrets, subjects or screen data in logs.

    def response(self, status, data, mime, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def json(self, status, obj):
        self.response(status, json.dumps(obj, ensure_ascii=False, allow_nan=False).encode(), "application/json; charset=utf-8")

    def handle_request(self):
        try:
            lengths = self.headers.get_all("Content-Length", [])
            if self.headers.get("Transfer-Encoding") or (lengths and
                    (len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,4}", lengths[0]) or int(lengths[0]) > 1024)):
                raise BridgeError(400, "请求长度无效")
            body = self.rfile.read(int(lengths[0])) if lengths else b""
            if self.headers.get("Origin"):
                raise BridgeError(403, "请求来源或格式不受支持")
            pairing = self.command == "POST" and self.path in PAIR_ROUTES
            if not pairing:
                auth = self.headers.get_all("Authorization", [])
                if len(auth) != 1 or not hmac.compare_digest(auth[0].encode(), self.server.bearer):
                    raise BridgeError(401, "配对无效，请在 Mac 上重新配对")
                routes = {("GET", "/v1/status"), ("GET", "/v1/frame"),
                          ("POST", "/v1/tap"), ("POST", "/v1/connect")}
                if (self.command, self.path) not in routes:
                    raise BridgeError(404, "未知操作")
            params = {}
            if self.command == "POST":
                if not lengths:
                    raise BridgeError(400, "请求长度无效")
                if self.headers.get_content_type() != "application/json":
                    raise BridgeError(415, "请求需要 JSON 格式")
                try:
                    params = json.loads(body or b"{}")
                except ValueError:
                    raise BridgeError(400, "请求格式无效")
                if not isinstance(params, dict):
                    raise BridgeError(400, "请求格式无效")
            if pairing:
                self.exchange(params)
                return
            if not self.server.action.acquire(timeout=1.0):
                raise BridgeError(503, "电脑正在处理上一次操作，请稍后刷新")
            try:
                self.dispatch(params)
            finally:
                self.server.action.release()
        except BridgeError as err:
            self.json(err.status, {"error": err.message})

    do_GET = handle_request
    do_POST = handle_request

    def exchange(self, params):
        try:
            private_address(self.client_address[0])
        except ValueError:
            raise BridgeError(403, "请先连接电脑所在的局域网或私人网络")
        with self.server.offer_lock:
            offer = self.server.offer
            if offer is None:
                raise BridgeError(409, "请在 Mac 的手机配对窗口获取新的六位配对码")
            try:
                if self.path == "/v1/pair/start":
                    reply = offer.begin(params)
                else:
                    reply = offer.finish(params)
                    # Only a winning proof can release the existing long-term credential.
                    reply["link"] = self.server.pairing_url
            except ShortCodeError as err:
                raise BridgeError(err.status, str(err))
        self.json(200, reply)

    def dispatch(self, params):
        run = self.server.native
        if self.path == "/v1/status":
            self.json(200, run("status"))
        elif self.path == "/v1/connect":
            if params:
                raise BridgeError(400, "连接请求不接受额外参数")
            self.server.frame_id = None
            self.json(200, run("connect"))
        elif self.path == "/v1/frame":
            self.server.frame_id = None
            obj = run("frame")
            try:
                frame = obj["frameId"]
                if not isinstance(frame, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", frame):
                    raise ValueError()
                jpg = base64.b64decode(obj["jpeg"], validate=True)
                if not (4 <= len(jpg) <= 8 * 1024 * 1024 and jpg.startswith(b"\xff\xd8")):
                    raise ValueError()
            except (KeyError, TypeError, ValueError):
                raise BridgeError(502, "电脑端返回的画面无效")
            self.server.frame_id = frame
            self.server.frame_time = time.monotonic()
            self.response(200, jpg, "image/jpeg", {"X-Frame-Id": frame})
        else:
            if set(params) != {"frameId", "x", "y"}:
                raise BridgeError(400, "缺少画面编号或点击位置")
            for field in ("x", "y"):
                value = params[field]
                if type(value) not in (float, int) or not (0 <= value <= 1 and math.isfinite(value)):
                    raise BridgeError(400, "点击位置不在画面内")
            if (not self.server.frame_id or params["frameId"] != self.server.frame_id
                    or time.monotonic() - self.server.frame_time > 25):
                raise BridgeError(409, "画面已更新，请刷新后重新点按")
            self.server.frame_id = None
            self.json(200, run("tap", params["frameId"], str(params["x"]), str(params["y"])))


class PrivateServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

    def __init__(self, addr, tls, key, native):
        self.context = tls
        self.bearer = ("Bearer " + key).encode()
        self.native = native
        self.workers = threading.BoundedSemaphore(8)
        self.action = threading.Lock()
        self.frame_id = None
        self.offer = None
        self.offer_lock = threading.Lock()
        self.pairing_url = None
        super().__init__(addr, MonitorAPI)

    def process_request(self, request, client_address):
        if self.workers.acquire(blocking=False):
            super().process_request(request, client_address)
        else:
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(8)
            with self.context.wrap_socket(request, server_side=True) as tls:
                tls.settimeout(25)
                self.finish_request(tls, client_address)
        except (ssl.SSLError, OSError):
            pass
        finally:
            self.shutdown_request(request)
            self.workers.release()


def show_code(server, pin):
    with server.offer_lock:
        server.offer = ShortCodeOffer(pin)
        # Only the Mac pairing window receives these local pipe messages.
        print(json.dumps({"url": server.pairing_url, "code": server.offer.code, "expiresIn": 300}), flush=True)


def serve_pairing_window(server, pin):
    parent = os.getppid()
    command_fd = sys.stdin.fileno()
    readers = [server, command_fd]
    buffer = b""
    notified = False
    show_code(server, pin)
    while parent != 1 and os.getppid() == parent:
        ready, _, _ = select.select(readers, [], [], 1.0)
        if command_fd in ready:
            chunk = os.read(command_fd, 256)
            if not chunk:
                return  # The Mac pairing window owns this listener.
            else:
                buffer += chunk
                while b"\n" in buffer:
                    command, buffer = buffer.split(b"\n", 1)
                    if command == b"renew":
                        show_code(server, pin)
                        notified = False
                if len(buffer) > 256:
                    buffer = b""
        if server in ready:
            server.handle_request()
        if not notified:
            reason = server.offer.closed_reason
            if reason:
                print(json.dumps({"event": "codeClosed", "reason": reason}), flush=True)
                notified = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True, type=private_address)
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--apps", type=Path, required=True)
    parser.add_argument("--private-dir", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--rotate", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    root = args.private_dir
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    stat = root.lstat()
    if root.is_symlink() or not root.is_dir() or stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise ValueError("手机配对数据目录权限无效")
    if not args.helper.is_file() or not os.access(args.helper, os.X_OK):
        raise ValueError("电脑端组件缺失，请重新打开完整的手机配对应用")
    with (root / "bridge.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("已有配对服务在运行，请先关闭旧窗口中的服务")
        cert, pem, pin = identity(root, args.bind)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(cert, pem)
        key = pairing_key(root, args.rotate)
        native = NativeMonitor(args.helper, args.apps)
        with PrivateServer((args.bind, args.port), tls, key, native) as server:
            host = "https://%s:%s" % server.server_address
            server.pairing_url = "mailmonitor://pair?" + urlencode({"url": host, "pin": pin, "key": key})
            serve_pairing_window(server, pin)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)[:180]}), flush=True)
        raise SystemExit(1)
