import subprocess
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

import main

JPEG = b"\xff\xd8\xfftest-image"


class APITests(unittest.TestCase):
    def setUp(self):
        self.binary = patch.object(main, "BINARY", sys.executable)
        self.key = patch.object(main, "API_KEY", "")
        self.binary.start()
        self.key.start()
        self.addCleanup(self.binary.stop)
        self.addCleanup(self.key.stop)
        stack = ExitStack()
        self.addCleanup(stack.close)
        self.client = stack.enter_context(TestClient(main.app))

    def upload(self, data=JPEG, mime="image/jpeg", **kwargs):
        return self.client.post("/analyze", files={"image": ("../../private.jpg", data, mime)}, **kwargs)

    def test_health_and_version(self):
        self.assertEqual(self.client.get("/health").json(), {"status": "ok"})
        self.assertEqual(self.client.get("/version").json(), {"service": "argent-vision-api", "version": "0.1.0"})

    def test_invalid_type_and_signature(self):
        with patch.object(main.subprocess, "run") as run:
            self.assertEqual(self.upload(mime="text/plain").status_code, 415)
            self.assertEqual(self.upload(data=b"not an image").status_code, 415)
            run.assert_not_called()

    def test_api_key(self):
        with patch.object(main, "API_KEY", "test-key"), patch.object(main.subprocess, "run") as run:
            self.assertEqual(self.upload().status_code, 401)
            self.assertEqual(self.upload(headers={"X-API-Key": "wrong"}).status_code, 401)
            self.assertEqual(self.client.get("/health").status_code, 200)
            run.assert_not_called()
            run.return_value = subprocess.CompletedProcess([], 0, b'{}', b'')
            self.assertEqual(self.upload(headers={"X-API-Key": "test-key"}).status_code, 200)

    def test_subprocess_outcomes_and_cleanup(self):
        payload = b'{ "image": "/tmp/example.jpg", "classifications": [], "person_count": 0 }'
        outcomes = [
            (subprocess.CompletedProcess([], 0, payload, b""), 200),
            (subprocess.CompletedProcess([], 7, b"", b"private diagnostic"), 500),
            (subprocess.TimeoutExpired("vision", 10, stderr=b"timeout"), 504),
            (subprocess.CompletedProcess([], 0, b"invalid", b"bad JSON"), 502),
            (subprocess.CompletedProcess([], 0, b"NaN", b""), 502),
            (OSError("missing executable"), 500),
        ]
        for outcome, status in outcomes:
            with self.subTest(status=status, outcome=outcome):
                paths = []

                def invoke(args, **kwargs):
                    self.assertEqual(args[0], sys.executable)
                    self.assertEqual(len(args), 2)
                    path = Path(args[1])
                    paths.append(path)
                    self.assertEqual(path.read_bytes(), JPEG)
                    self.assertNotIn("private.jpg", path.name)
                    self.assertFalse(kwargs["shell"])
                    self.assertEqual(kwargs["timeout"], main.TIMEOUT)
                    if isinstance(outcome, Exception):
                        raise outcome
                    return outcome

                with patch.object(main.subprocess, "run", side_effect=invoke):
                    response = self.upload()
                self.assertEqual(response.status_code, status)
                self.assertTrue(paths)
                self.assertFalse(paths[0].exists())
                if status == 200:
                    self.assertEqual(response.content, payload)
                else:
                    self.assertNotIn("private diagnostic", response.text)

    def test_size_limit_and_png(self):
        with patch.object(main, "MAX_UPLOAD_BYTES", 8), patch.object(main.subprocess, "run") as run:
            self.assertEqual(self.upload().status_code, 413)
            run.assert_not_called()
        with patch.object(main.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b'{}', b'')):
            self.assertEqual(self.upload(data=b"\x89PNG\r\n\x1a\ntest", mime="image/png").status_code, 200)

    def test_invalid_startup(self):
        for binary in ("relative-path", "/nonexistent/argent-vision", __file__):
            with self.subTest(binary=binary), patch.object(main, "BINARY", binary):
                with self.assertRaises(RuntimeError):
                    with TestClient(main.app):
                        pass
        with patch.object(main, "TIMEOUT", -1):
            with self.assertRaises(RuntimeError):
                with TestClient(main.app):
                    pass


if __name__ == "__main__":
    unittest.main()
