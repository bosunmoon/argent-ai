"""Run after swift build: python3 apple-vision/tests/test_http.py [image.jpg]."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest

IMAGE = Path(sys.argv.pop()).resolve() if len(sys.argv) > 1 else None
BINARY = Path(os.environ.get("ARGENT_VISION_BINARY", str(Path(__file__).resolve().parents[1] / ".build/debug/argent-vision"))).resolve()


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        cls.server = subprocess.Popen([str(BINARY), "serve", "--port", str(cls.port)])
        cls.addClassCleanup(cls.stop_server)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.1):
                    return
            except OSError:
                if cls.server.poll() is not None:
                    raise RuntimeError("Server exited during startup")
                time.sleep(0.05)
        raise RuntimeError("Server did not start")

    @classmethod
    def stop_server(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)

    def request(self, method="POST", path="/detect", body=b"invalid", headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            connection.request(method, path, body, headers or {})
            response = connection.getresponse()
            self.assertEqual(response.getheader("Content-Type"), "application/json")
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_errors_and_recovery(self):
        for kwargs, expected in [
            ({"method": "GET"}, 405),
            ({"path": "/missing"}, 404),
            ({"headers": {"Content-Type": "multipart/form-data"}}, 415),
            ({"headers": {"Content-Length": str(20 * 1024 * 1024 + 1)}}, 413),
            ({"body": b""}, 400),
            ({}, 422),
        ]:
            with self.subTest(expected=expected):
                status, body = self.request(**kwargs)
                self.assertEqual(status, expected)
                self.assertIn("error", body)

    def test_missing_length_and_chunked(self):
        for headers, expected in [(b"", 411), (b"Transfer-Encoding: chunked\r\n", 400)]:
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
                sock.sendall(b"POST /detect HTTP/1.1\r\nHost: localhost\r\n" + headers + b"\r\n")
                self.assertIn(str(expected).encode(), sock.recv(4096).split(b"\r\n")[0])

    @unittest.skipUnless(IMAGE, "Pass an image path to test real Vision inference")
    def test_image_matches_cli(self):
        cli = json.loads(subprocess.check_output([str(BINARY), str(IMAGE)]))
        status, result = self.request(body=IMAGE.read_bytes(), headers={"Content-Type": "image/jpeg"})
        self.assertEqual(status, 200, result)
        self.assertEqual(result.pop("image"), "upload")
        cli.pop("image")
        result.pop("elapsed_ms")
        cli.pop("elapsed_ms")
        self.assertEqual(result, cli)


if __name__ == "__main__":
    unittest.main()
