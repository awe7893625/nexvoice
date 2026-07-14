import base64
import hashlib
import hmac
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


RUNTIME = Path(__file__).with_name("nexvoice_local_runtime.py")


def _proof(secret: bytes, message: str) -> str:
    digest = hmac.new(secret, message.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


def _request_message(method: str, path: str, nonce: str, body: bytes) -> str:
    return f"{method}\n{path}\n{nonce}\n{hashlib.sha256(body).hexdigest()}"


class RuntimeHTTPContractTests(unittest.TestCase):
    SECRET = b"test-token"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        home = Path(self.temp.name)
        token_file = home / ".cache" / "nexvoice" / "local-runtime.token"
        token_file.parent.mkdir(parents=True, mode=0o700)
        token_file.write_text(self.SECRET.decode(), encoding="utf-8")
        token_file.chmod(0o600)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.build = "sha256:" + hashlib.sha256(RUNTIME.read_bytes()).hexdigest()
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "NEXVOICE_LOCAL_PORT": str(self.port),
                "NEXVOICE_RUNTIME_EXPECTED_BUILD": self.build,
                "NEXVOICE_RUNTIME_OWNER_NONCE": "test-owner",
                "NEXVOICE_RUNTIME_PARENT_PID": str(os.getpid()),
            }
        )
        self.process = subprocess.Popen(
            [sys.executable, str(RUNTIME)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        for _ in range(50):
            try:
                self.health = self.request("GET", "/health")
                break
            except (OSError, urllib.error.URLError):
                if self.process.poll() is not None:
                    self.fail(self.process.stderr.read())
                time.sleep(0.05)
        else:
            self.fail("runtime did not become ready")

    def tearDown(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=3)
        if self.process.stderr is not None:
            self.process.stderr.close()
        self.temp.cleanup()

    def request(self, method, path, *, body=None, secret=None, nonce="fixed-nonce", authorize=True):
        secret = self.SECRET if secret is None else secret
        data = json.dumps(body).encode() if body is not None else b""
        headers = {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if authorize:
            headers["X-NexVoice-Local-Nonce"] = nonce
            headers["X-NexVoice-Local-Proof"] = _proof(
                secret, _request_message(method, path, nonce, data)
            )
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=data if body is not None else None,
            headers=headers,
            method=method,
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            return json.loads(response.read())

    def test_health_never_transmits_the_secret_and_response_proof_verifies(self):
        self.assertEqual(self.health["contract_version"], 2)
        self.assertEqual(self.health["runtime_build"], self.build)
        self.assertEqual(self.health["owner_nonce"], "test-owner")
        self.assertIn("shutdown-v1", self.health["capabilities"])
        self.assertIn("challenge-response-v1", self.health["capabilities"])

        expected_message = (
            f"health\nfixed-nonce\n{self.health['instance_id']}\n{self.build}\ntest-owner\n2"
        )
        self.assertEqual(self.health["response_proof"], _proof(self.SECRET, expected_message))

    def test_request_without_a_valid_proof_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as unauthorized:
            self.request("GET", "/health", authorize=False)
        self.assertEqual(unauthorized.exception.code, 401)
        unauthorized.exception.close()

    def test_port_squatter_without_secret_file_access_cannot_authenticate(self):
        # The squatter can freely connect and guess a secret, but never reads
        # the real 0600 token file, so its proof never matches (P0-E).
        with self.assertRaises(urllib.error.HTTPError) as forged:
            self.request("GET", "/health", secret=b"guessed-secret")
        self.assertEqual(forged.exception.code, 401)
        forged.exception.close()

    def test_tampered_body_after_proof_is_computed_is_rejected(self):
        # Simulates a captured proof being replayed against a different payload.
        nonce = "fixed-nonce"
        real_body = json.dumps({"instance_id": "x", "runtime_build": "y", "owner_nonce": "z"}).encode()
        proof = _proof(self.SECRET, _request_message("POST", "/control/shutdown", nonce, real_body))
        tampered_body = json.dumps({"instance_id": "x", "runtime_build": "y", "owner_nonce": "different"}).encode()
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/control/shutdown",
            data=tampered_body,
            headers={
                "Content-Type": "application/json",
                "X-NexVoice-Local-Nonce": nonce,
                "X-NexVoice-Local-Proof": proof,
            },
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as tampered:
            urllib.request.urlopen(request, timeout=2)
        self.assertEqual(tampered.exception.code, 401)
        tampered.exception.close()

    def test_guarded_self_shutdown_requires_exact_identity_and_returns_verifiable_proof(self):
        wrong = {
            "instance_id": self.health["instance_id"],
            "runtime_build": self.build,
            "owner_nonce": "wrong",
        }
        with self.assertRaises(urllib.error.HTTPError) as mismatch:
            self.request("POST", "/control/shutdown", body=wrong)
        self.assertEqual(mismatch.exception.code, 409)
        mismatch.exception.close()
        self.assertIsNone(self.process.poll())

        exact = dict(wrong, owner_nonce="test-owner")
        response = self.request("POST", "/control/shutdown", body=exact)
        self.assertEqual(response["status"], "shutting_down")
        expected = _proof(self.SECRET, f"shutdown\nfixed-nonce\n{self.health['instance_id']}")
        self.assertEqual(response["response_proof"], expected)
        self.process.wait(timeout=3)
        self.assertIsNotNone(self.process.returncode)

    def test_new_transcription_requests_are_refused_once_shutdown_is_requested(self):
        exact = {
            "instance_id": self.health["instance_id"],
            "runtime_build": self.build,
            "owner_nonce": "test-owner",
        }
        response = self.request("POST", "/control/shutdown", body=exact)
        self.assertEqual(response["status"], "shutting_down")

        # The listening socket may already be closed by the time this second
        # request lands (shutdown+close races the test's own next connection),
        # so either outcome is acceptable -- the one thing that must never
        # happen is a 200 with an accepted/processed transcription.
        try:
            self.request(
                "POST",
                "/",
                body={
                    "audio_base64": base64.b64encode(b"\x00\x00").decode(),
                    "session": "00000000-0000-0000-0000-000000000000",
                    "sequence": 0,
                    "quality": "final",
                },
            )
            self.fail("a transcription request must not be accepted once shutdown was requested")
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 503)
            error.close()
        except (ConnectionResetError, urllib.error.URLError):
            pass
        self.process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
