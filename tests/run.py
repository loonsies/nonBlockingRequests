"""Test the Lua client against local HTTP and HTTPS servers."""

import argparse
import contextlib
import fnmatch
import hashlib
import json
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time
import unittest
import xml.etree.ElementTree as ET


BODY = b"0123456789abcdef"
POST_BODY = b"A" * 8000 + b"B" * 8000 + b"C" * 8000
CASES = (
    "http_fixed", "https_fixed", "https_fragmented_body", "https_chunked",
    "https_split_status", "https_split_header", "https_split_chunk_size",
    "https_split_chunk_terminator", "https_redirect", "http_upgrade",
    "https_redirect_limit", "https_post", "https_backpressure",
    "https_concurrent", "https_cancel", "https_truncated_body", "invalid_url",
)


class Peer(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(4)
        try:
            if self.server.context:
                conn = self.server.context.wrap_socket(conn, server_side=True)
            if self.server.scenario == "https_backpressure":
                # Pause reads to make the client's send buffer fill.
                time.sleep(1)
            self.respond(conn)
            if self.server.context:
                # Close TLS cleanly when the client allows it.
                with contextlib.suppress(OSError, ssl.SSLError):
                    conn.settimeout(1)
                    conn.unwrap()
        except (OSError, ssl.SSLError):
            # Some tests cancel or close the connection early.
            pass
        finally:
            conn.close()

    def respond(self, conn):
        data = b""
        while b"\r\n\r\n" not in data:
            part = conn.recv(8192)
            if not part:
                return
            data += part
            if len(data) > 65536:
                raise ValueError("Request headers exceed fixture limit")
        header, body = data.split(b"\r\n\r\n", 1)
        lines = header.decode("ascii").split("\r\n")
        method, path, _ = lines[0].split(" ", 2)
        headers = dict(line.split(":", 1) for line in lines[1:])
        headers = {k.lower(): v.strip() for k, v in headers.items()}
        length = int(headers.get("content-length", "0"))
        if not 0 <= length <= 65536:
            raise ValueError("Request body exceeds fixture limit")
        while len(body) < length:
            part = conn.recv(8192)
            if not part:
                return
            body += part
        with self.server.lock:
            self.server.requests.append({"method": method, "path": path,
                                         "headers": headers, "body": body})

        fixed = b"HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n"
        chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        encoded = b"10\r\n" + BODY + b"\r\n0\r\n\r\n"
        pieces = [fixed + BODY]
        if path == "/fragmented_body":
            pieces = [fixed + BODY[:5], BODY[5:]]
        elif path == "/chunked":
            pieces = [chunked + encoded]
        elif path == "/split_status":
            pieces = [b"HTTP/1.1 2", fixed[len(b"HTTP/1.1 2"):] + BODY]
        elif path == "/split_header":
            pieces = [b"HTTP/1.1 200 OK\r\nTransfer-Enco",
                      b"ding: chunked\r\nConnection: close\r\n\r\n" + encoded]
        elif path == "/split_chunk_size":
            pieces = [chunked + b"1", b"0\r\n" + BODY + b"\r\n0\r\n\r\n"]
        elif path == "/split_chunk_terminator":
            pieces = [chunked + b"10\r\n" + BODY + b"\r", b"\n0\r\n\r\n"]
        elif path in ("/redirect", "/upgrade", "/redirect_limit"):
            location = {"/redirect": "/fixed", "/upgrade": self.server.https_url + "/fixed",
                        "/redirect_limit": "/redirect_limit"}[path]
            pieces = [("HTTP/1.1 302 Found\r\nLocation: " + location +
                       "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").encode()]
        elif path in ("/post", "/backpressure"):
            pieces = [b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"]
        elif path == "/truncated_body":
            pieces = [fixed + b"short"]
        for index, piece in enumerate(pieces):
            if index:
                time.sleep(0.3)
            conn.sendall(piece)


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def __init__(self, scenario, context=None):
        self.context, self.scenario = context, scenario
        self.requests, self.lock = [], threading.Lock()
        self.https_url = ""
        super().__init__(("127.0.0.1", 0), Peer, bind_and_activate=False)
        if scenario == "https_backpressure":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        self.server_bind()
        self.server_activate()
        self.thread = threading.Thread(target=self.serve_forever,
                                       kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return ("https" if self.context else "http") + "://127.0.0.1:" + str(self.server_address[1])

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


class IntegrationTest(unittest.TestCase):
    def __init__(self, config, context, case, live_url=None):
        super().__init__()
        self.config, self.context = config, context
        self.case, self.live_url = case, live_url
        self.observation = None
        self.log = ""
        self.duration = 0

    def __str__(self):
        return self.case

    def shortDescription(self):
        return None

    def runTest(self):
        if self.live_url:
            result = self.client(self.live_url, 10, 5, "get")
            self.check_completed(result, 10, 5)
            for response in result["results"]:
                self.assertFalse(response.get("error"), response)
                self.assertGreaterEqual(response.get("status", 0), 200)
                self.assertLess(response["status"], 400)
            return

        secure = Server(self.case, self.context)
        plain = Server(self.case)
        plain.https_url = secure.url
        try:
            route = self.case.split("_", 1)[-1]
            target = (plain.url if self.case.startswith("http_") else secure.url) + "/" + route
            kind, total, concurrency = "get", 1, 1
            if self.case == "https_concurrent":
                total, concurrency = 12, 5
            elif self.case == "https_cancel":
                kind = "cancel"
            elif self.case in ("https_post", "https_backpressure"):
                kind = route
            elif self.case == "invalid_url":
                target = "ftp://127.0.0.1/"
            result = self.client(target, total, concurrency, kind)
            self.check_completed(result, total, concurrency)
            requests = secure.requests + plain.requests

            if self.case in ("https_redirect_limit", "https_truncated_body", "invalid_url"):
                expected = {"https_redirect_limit": "Too many redirects",
                            "https_truncated_body": "Connection closed before body finished",
                            "invalid_url": "Unsupported scheme"}[self.case]
                self.assertIn(expected, result["results"][0].get("error", ""))
                if self.case == "invalid_url":
                    self.assertEqual(len(requests), 0)
                return

            if "split_" in self.case and self.case != "https_split_chunk_terminator":
                self.assertGreater(result["metrics"]["partialLines"], 0,
                                   "Fixture did not cause a partial line; result is inconclusive")
            if self.case == "https_backpressure":
                self.assertGreater(result["metrics"]["sendRetries"], 0,
                                   "Fixture did not cause backpressure; result is inconclusive")
            for response in result["results"]:
                self.assertFalse(response.get("error"), response)
                self.assertEqual(response.get("status"), 200, response)
                expected = "ok" if kind in ("post", "backpressure") else BODY.decode()
                self.assertEqual(response.get("body"), expected)
                self.assertEqual(response.get("bodyBytes"), len(expected))
            expected_requests = total + (1 if self.case in ("https_redirect", "http_upgrade") else 0)
            self.assertEqual(len(requests), expected_requests)
            for request in requests:
                self.assertEqual(request["headers"].get("x-test"), "standalone")
            if kind in ("post", "backpressure"):
                self.assertEqual(requests[0]["method"], "POST")
                self.assertEqual(requests[0]["body"], POST_BODY if kind == "backpressure" else b"hello=Ashita")
        finally:
            secure.close()
            plain.close()

    def check_completed(self, result, total, concurrency):
        self.assertFalse(result["timedOut"], "Client exceeded its 12-second deadline")
        self.assertEqual(result["completed"], total)
        self.assertEqual(len(result["results"]), total)
        self.assertEqual(len({response["id"] for response in result["results"]}), total)
        self.assertEqual(result["metrics"]["unexpectedCallbacks"], 0)
        self.assertEqual(result["activeAfterCleanup"], 0)
        self.assertLessEqual(result["metrics"]["peakActive"], concurrency)
        self.assertEqual(result["metrics"]["peakActive"], min(total, concurrency))
        self.assertEqual(result["environment"]["arch"], "x86")
        self.assertTrue(result["environment"]["vm"].startswith("moonjit "))

    def client(self, target, total, concurrency, kind):
        command = [str(self.config.lua), str(Path(__file__).with_name("client.lua")),
                   str(self.config.ashita), str(self.config.library), target,
                   str(total), str(concurrency), kind]
        begin = time.monotonic()
        try:
            process = subprocess.run(command, capture_output=True, text=True, timeout=18)
            self.log = process.stdout + process.stderr
            self.assertEqual(process.returncode, 0, self.log)
            lines = [line[12:] for line in process.stdout.splitlines() if line.startswith("TEST_RESULT ")]
            self.assertEqual(len(lines), 1, self.log)
            self.observation = json.loads(lines[0])
            return self.observation
        except subprocess.TimeoutExpired as error:
            self.log = "Client exceeded external 18-second deadline.\n" + str(error.stdout)
            self.fail(self.log)
        finally:
            self.duration = time.monotonic() - begin
            (self.config.output / (str(self) + ".log")).write_text(self.log, encoding="utf-8")


class Results(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []

    def record(self, test, status, detail=""):
        self.records.append({"name": str(test), "status": status, "detail": detail,
                             "duration": test.duration, "observation": test.observation,
                             "log": test.log})

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, "passed")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.record(test, "failed", self._exc_info_to_string(err, test))

    def addError(self, test, err):
        super().addError(test, err)
        self.record(test, "error", self._exc_info_to_string(err, test))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("lua", "ashita", "library", "openssl", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--case", default="*")
    parser.add_argument("--live-url", action="append", default=[])
    config = parser.parse_args()
    config.output.mkdir(parents=True, exist_ok=True)
    cases = [case for case in CASES if fnmatch.fnmatchcase(case, config.case)]
    live_cases = [("live_" + str(index + 1), url) for index, url in enumerate(config.live_url)]
    live_cases = [(name, url) for name, url in live_cases if fnmatch.fnmatchcase(name, config.case)]
    if not cases and not live_cases:
        parser.error("No tests matched --case")

    certs = config.output / "certs"
    certs.mkdir(exist_ok=True)
    process = subprocess.run([str(config.openssl), "req", "-x509", "-newkey", "rsa:2048",
                              "-nodes", "-keyout", str(certs / "key.pem"), "-out", str(certs / "cert.pem"),
                              "-subj", "/CN=localhost", "-days", "1"], capture_output=True, text=True, timeout=30)
    if process.returncode:
        print(process.stderr, file=sys.stderr)
        return 2
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certs / "cert.pem", certs / "key.pem")
    suite = unittest.TestSuite()
    for case in cases:
        suite.addTest(IntegrationTest(config, context, case))
    for name, url in live_cases:
        suite.addTest(IntegrationTest(config, context, name, url))
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2, resultclass=Results).run(suite)
    files = [config.library, config.ashita / "plugins/addons.dll",
             config.ashita / "addons/libs/socket/ssl.dll", config.lua]
    report = {"python": sys.version, "server_tls": ssl.OPENSSL_VERSION,
              "fingerprints": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
              "tests": result.records}
    (config.output / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    xml = ET.Element("testsuite", name="Ashita HTTP integration", tests=str(result.testsRun),
                     failures=str(len(result.failures)), errors=str(len(result.errors)))
    for record in result.records:
        case = ET.SubElement(xml, "testcase", name=record["name"], time=f'{record["duration"]:.3f}')
        if record["status"] != "passed":
            ET.SubElement(case, "failure" if record["status"] == "failed" else "error").text = record["detail"]
        ET.SubElement(case, "system-out").text = record["log"]
    ET.ElementTree(xml).write(config.output / "junit.xml", encoding="utf-8", xml_declaration=True)
    print(f"Reports: {config.output.resolve()}")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
