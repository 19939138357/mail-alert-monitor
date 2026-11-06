"""Regression checks for bounded, single-use SRP handshakes; no production credentials."""
import concurrent.futures
import secrets
import threading
import unittest
from unittest.mock import patch

from short_code import (G, K, N, ShortCodeError, ShortCodeOffer, hash_parts,
                        integer, padded_hash)


class OfferTests(unittest.TestCase):
    def setUp(self):
        self.pin = "31" * 32
        self.code = "000012"
        self.offer = ShortCodeOffer(self.pin, self.code)

    def transcript(self, *, pin=None, code=None):
        a = 2**255 + secrets.randbits(255)
        public = pow(G, a, N)
        start = self.offer.begin({"A": "%0512x" % public})
        x = integer(hash_parts(bytes.fromhex(start["salt"]),
                    hash_parts(("mailmonitor-v1/" + (pin or self.pin) + ":" + (code or self.code)).encode())))
        b = int(start["B"], 16)
        u = integer(padded_hash(public, b))
        shared = pow((b - K * pow(G, x, N)) % N, a + u*x, N)
        m1 = padded_hash(public, b, shared)
        return {"id": start["id"], "proof": m1.hex()}, padded_hash(public, integer(m1), shared).hex()

    def test_one_time_and_competing_devices(self):
        challenge, m2 = self.transcript()
        other, _ = self.transcript()
        gate = threading.Barrier(2)
        def finish():
            gate.wait()
            try:
                return self.offer.finish(challenge)
            except ShortCodeError as exc:
                return exc.status
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as exe:
            outcomes = list(exe.map(lambda _: finish(), range(2)))
        self.assertCountEqual(outcomes, [{"proof": m2}, 410])
        self.assertEqual(self.offer.closed_reason, "paired")
        with self.assertRaises(ShortCodeError):
            self.offer.finish(other)

    def test_cert_bound_and_no_retries_on_one_challenge(self):
        challenge, _ = self.transcript(pin="00"*32)
        with self.assertRaises(ShortCodeError) as err:
            self.offer.finish(challenge)
        self.assertEqual(err.exception.status,403)
        with self.assertRaises(ShortCodeError) as err:
            self.offer.finish(challenge)
        self.assertEqual(err.exception.status,410)
        challenge, _ = self.transcript(code="123456")
        with self.assertRaises(ShortCodeError) as err:
            self.offer.finish(challenge)
        self.assertEqual(err.exception.status,403)
        self.assertIsNone(self.offer.closed_reason)

    def test_brute_force_limit_and_fifth_finish(self):
        for _ in range(4):
            wrong, _ = self.transcript(code="919191")
            with self.assertRaises(ShortCodeError):
                self.offer.finish(wrong)
        final, expected = self.transcript()
        self.assertIsNone(self.offer.closed_reason)
        with self.assertRaises(ShortCodeError) as err:
            self.transcript()
        self.assertEqual(err.exception.status,429)
        self.assertEqual(self.offer.finish(final), {"proof": expected})

    def test_abandoned_challenges_and_replay(self):
        for _ in range(5):
            final, _ = self.transcript()
        with patch("short_code.time.monotonic",return_value=self.offer._started_monotonic+40):
            self.assertEqual(self.offer.closed_reason, "attempts")
            with self.assertRaises(ShortCodeError) as err:
                self.offer.finish(final)
            self.assertEqual(err.exception.status,429)

    def test_expiration_sleep_and_clock_rollback(self):
        final, _ = self.transcript()
        with patch("short_code.time.time",return_value=self.offer._started_wall+301):
            self.assertEqual(self.offer.closed_reason, "expired")
        with self.assertRaises(ShortCodeError) as err:
            self.offer.finish(final)
        self.assertEqual(err.exception.status,410)

    def test_invalid_public_values(self):
        for a in (0,1,N-1,N,N+1):
            with self.assertRaises(ShortCodeError):
                self.offer.begin({"A":"%0512x" % a})
        with self.assertRaises(ShortCodeError):
            self.offer.begin({"A":[]})

if __name__ == "__main__": unittest.main()
