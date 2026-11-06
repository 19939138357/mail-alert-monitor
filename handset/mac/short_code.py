"""One-time SRP-6a offer. RFC 5054 Appendix A group, SHA-256, BC padded M1/M2."""
import hashlib
import hmac
import re
import secrets
import threading
import time


N = int(
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294"
    "3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D"
    "CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB"
    "D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74"
    "7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A"
    "436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D"
    "5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73"
    "03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"
    "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F"
    "9E4AFF73", 16)
G = 2
WIDTH = 256
TTL = 300
CHALLENGE_TTL = 30
MAX_ATTEMPTS = 5


def hash_parts(*parts):
    return hashlib.sha256(b"".join(parts)).digest()


def padded_hash(*values):
    return hash_parts(*(n.to_bytes(WIDTH, "big") for n in values))


def integer(raw):
    return int.from_bytes(raw, "big")


K = integer(padded_hash(N, G))


class ShortCodeError(ValueError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class ShortCodeOffer:
    def __init__(self, pin, code=None):
        if not re.fullmatch("[0-9a-f]{64}", pin):
            raise ValueError("Invalid certificate fingerprint")
        self.code = ("%06d" % secrets.randbelow(1000000)) if code is None else code
        if not re.fullmatch("[0-9]{6}", self.code):
            raise ValueError("Invalid short code")
        # Using the actual TLS leaf in the SRP identity defeats credential forwarding
        # through an active peer presenting a different certificate.
        self._identity = ("mailmonitor-v1/" + pin).encode("ascii")
        self._started_monotonic = time.monotonic()
        self._started_wall = time.time()
        self._high_water = 0.0
        self._count = 0
        self._paired = False
        self._pending = {}
        self._lock = threading.Lock()

    def _elapsed(self):
        # macOS may pause its monotonic clock during sleep.
        self._high_water = max(self._high_water, time.monotonic() - self._started_monotonic,
                               time.time() - self._started_wall)
        return self._high_water

    def _closed(self, now):
        self._pending = {k: v for k, v in self._pending.items() if v[0] > now}
        if self._paired:
            return "paired"
        if now >= TTL:
            self._pending.clear()
            return "expired"
        if self._count >= MAX_ATTEMPTS and not self._pending:
            return "attempts"
        return None

    @property
    def closed_reason(self):
        with self._lock:
            return self._closed(self._elapsed())

    def _check_active(self, now):
        reason = self._closed(now)
        if reason == "attempts":
            raise ShortCodeError(429, "尝试次数已用完，请在 Mac 上换一个配对码")
        if reason is not None:
            raise ShortCodeError(410, "配对码已使用或过期，请在 Mac 上换一个配对码")

    def begin(self, data):
        if not isinstance(data, dict) or set(data) != {"A"} or not isinstance(data["A"], str) or not re.fullmatch("[0-9a-f]{512}", data["A"]):
            raise ShortCodeError(400, "配对请求格式错误")
        public = int(data["A"], 16)
        if not 1 < public < N - 1:
            raise ShortCodeError(400, "配对参数无效")
        with self._lock:
            now = self._elapsed()
            self._check_active(now)
            if self._count >= MAX_ATTEMPTS:
                raise ShortCodeError(429, "当前配对码已达尝试上限，请在 Mac 上换码")
            self._count += 1
            salt = secrets.token_bytes(16)
            x = integer(hash_parts(salt, hash_parts(self._identity, b":", self.code.encode("ascii"))))
            verifier = pow(G, x, N)
            secret = secrets.randbits(256) | (1 << 255)
            server = (K * verifier + pow(G, secret, N)) % N
            scramble = integer(padded_hash(public, server))
            if server == 0 or scramble == 0:
                raise ShortCodeError(503, "请重新开始配对")
            shared = pow(public * pow(verifier, scramble, N) % N, secret, N)
            m1 = padded_hash(public, server, shared)
            m2 = padded_hash(public, integer(m1), shared)
            request_id = secrets.token_hex(16)
            self._pending[request_id] = (now + CHALLENGE_TTL, m1, m2)
            return {"id": request_id, "salt": salt.hex(), "B": "%0512x" % server}

    def finish(self, data):
        if not isinstance(data, dict) or set(data) != {"id", "proof"} or not isinstance(data["id"], str) or not isinstance(data["proof"], str):
            raise ShortCodeError(400, "配对请求格式错误")
        if not re.fullmatch("[0-9a-f]{32}", data["id"]) or not re.fullmatch("[0-9a-f]{64}", data["proof"]):
            raise ShortCodeError(400, "配对请求格式错误")
        with self._lock:
            self._check_active(self._elapsed())
            challenge = self._pending.pop(data["id"], None)
            if challenge is None:
                raise ShortCodeError(410, "本次配对已结束，请重新输入当前配对码")
            if not hmac.compare_digest(challenge[1], bytes.fromhex(data["proof"])):
                raise ShortCodeError(403, "六位配对码不正确，请核对 Mac 上显示的数字")
            self._paired = True
            self._pending.clear()
            return {"proof": challenge[2].hex()}
