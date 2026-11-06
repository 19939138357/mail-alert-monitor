"""Exercise the actual private HTTPS listener with an isolated simulated mailbox."""
import base64
import hashlib
import http.client
import json
from pathlib import Path
import ssl
import tempfile
import threading
import unittest

import bridge


class PrivateAPITest(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parents[2] / ".build" / "pair-test"
        scratch.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=scratch)
        root = Path(self.scratch.name)
        self.cert, pem, self.pin = bridge.identity(root, "127.0.0.1")
        self.key = bridge.pairing_key(root)
        self.assertEqual(self.key, bridge.pairing_key(root))
        self.assertEqual(len(self.pin), 64)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(self.cert, pem)
        self.calls = []
        def monitor(*args):
            self.calls.append(args)
            if args[0] == "frame":
                return {"jpeg": base64.b64encode(b"\xff\xd8fixture\xff\xd9").decode(), "frameId": "demo-1"}
            if args[0] == "status":
                return {"monitorState": "fixture", "running": False, "tickets": []}
            return {}
        self.server = bridge.PrivateServer(("127.0.0.1", 0), tls, self.key, monitor)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.scratch.cleanup()

    def request(self, method, path, body=None, key=True, origin=False):
        # Match the phone's trust model. Verify the paired leaf and its IP before attaching a bearer.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection(*self.server.server_address, timeout=3, context=context)
        conn.connect()
        self.assertEqual(hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest(), self.pin)
        self.assertIn(("IP Address", "127.0.0.1"), ssl._ssl._test_decode_cert(str(self.cert))["subjectAltName"])
        headers = {}
        if key:
            headers["Authorization"] = "Bearer " + self.key
        if body is not None:
            headers["Content-Type"] = "application/json"
        if origin:
            headers["Origin"] = "https://unrelated.example"
        try:
            conn.request(method, path, None if body is None else json.dumps(body), headers)
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_private_scope(self):
        for ip in ["0.0.0.0", "8.8.8.8", "224.0.0.1", "169.254.1.1"]:
            with self.assertRaises(ValueError):
                bridge.private_address(ip)
        self.assertEqual("100.64.1.2", bridge.private_address("100.64.1.2"))
        self.assertEqual(self.request("GET", "/v1/status", key=False)[0], 401)
        self.assertEqual(self.request("POST", "/v1/connect", {}, origin=True)[0], 403)
        self.assertEqual(self.request("GET", "/v1/status?secret=x")[0], 404)
        self.assertEqual(self.request("POST", "/v1/connect", {"command":"whoami"})[0], 400)
        self.assertEqual(self.calls, [])
        code, headers, data = self.request("GET", "/v1/status")
        self.assertEqual((code, json.loads(data)["running"], headers["Cache-Control"]), (200, False, "no-store"))
        self.assertEqual(self.request("POST", "/v1/connect", {})[0], 200)

    def test_short_code_routes_are_isolated(self):
        route = "/v1/pair/start"
        self.assertEqual(self.request("POST", route, {}, key=False)[0], 409)
        self.server.offer = bridge.ShortCodeOffer(self.pin)
        self.server.pairing_url = "mailmonitor://pair?test-private-sentinel"
        # Browser-originated requests cannot enter a pairing exchange, and partial
        # or lookalike routes cannot bypass the existing mailbox authentication.
        self.assertEqual(self.request("POST", route, {}, key=False, origin=True)[0], 403)
        for method, path in [("GET", route), ("GET", "/v1/status"),
                             ("GET", "/v1/frame"), ("POST", "/v1/connect"),
                             ("POST", "/v1/tap"), ("POST", route + "?extra=1")]:
            result = self.request(method, path, {} if method == "POST" else None, key=False)
            self.assertEqual(result[0], 401)
        for path in (route, "/v1/pair/finish"):
            code, _, response = self.request("POST", path, {"code": self.server.offer.code}, key=False)
            self.assertTrue(400 <= code < 500)
            self.assertNotIn(self.server.pairing_url.encode(), response)
            self.assertNotIn(self.key.encode(), response)
            self.assertNotIn(self.server.offer.code.encode(), response)
        self.assertEqual(self.calls, [])
        # Old phones continue to work while a new code is pending.
        self.assertEqual(self.request("GET", "/v1/status")[0], 200)

    def test_only_once_per_frame(self):
        params = {"frameId":"demo-1", "x":0.25, "y":0.5}
        self.assertEqual(self.request("POST", "/v1/tap", params)[0], 409)
        code, headers, data = self.request("GET", "/v1/frame")
        self.assertEqual((code, headers["X-Frame-Id"], headers["Content-Type"]), (200, "demo-1", "image/jpeg"))
        self.assertEqual(self.request("POST", "/v1/tap", dict(params, x=True))[0], 400)
        self.assertEqual(self.request("POST", "/v1/tap", dict(params, x=-0.01))[0], 400)
        self.assertEqual(self.request("POST", "/v1/tap", params)[0], 200)
        self.assertEqual(self.request("POST", "/v1/tap", params)[0], 409)
        self.assertEqual(self.calls.count(("tap", "demo-1", "0.25", "0.5")), 1)
        self.request("GET", "/v1/frame")
        self.server.frame_time -= 30
        self.assertEqual(self.request("POST", "/v1/tap", params)[0], 409)

    def test_certificate_identity_and_revocation(self):
        root = Path(self.scratch.name)
        self.assertEqual(self.pin, bridge.identity(root, "127.0.0.1")[2])
        self.assertNotEqual(self.pin, bridge.identity(root, "192.168.1.1")[2])
        self.assertNotEqual(self.key, bridge.pairing_key(root, rotate=True))
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(*self.server.server_address, timeout=2, context=ctx)
        with self.assertRaises(ssl.SSLCertVerificationError):
            conn.request("GET", "/v1/status")
        conn.close()


if __name__ == "__main__":
    unittest.main()
