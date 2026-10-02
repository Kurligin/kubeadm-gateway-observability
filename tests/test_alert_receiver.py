"""Unit tests of the Alertmanager webhook receiver.

Run by `make lint` (python -m unittest discover tests).
"""

import io
import json
import socket
import sys
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# The module lives in a Helm chart: keep __pycache__ out of it.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "charts/observability-extras/files"))

import alert_receiver  # noqa: E402

NOTIFICATION: dict[str, Any] = {
    "version": "4",
    "groupKey": '{}/{}:{alertname="Watchdog"}',
    "status": "firing",
    "receiver": "alert-log",
    "externalURL": "https://alertmanager.demo.local",
    "alerts": [
        {
            "status": "firing",
            "labels": {"alertname": "Watchdog", "severity": "none", "prometheus": "monitoring/x"},
            "annotations": {"summary": "An alert that should always be firing."},
            "startsAt": "2026-10-01T12:00:00Z",
            "endsAt": "0001-01-01T00:00:00Z",
            "fingerprint": "abc",
        },
        {
            "status": "resolved",
            "labels": {"alertname": "AppDown", "severity": "critical", "deployment": "web-v1"},
            "annotations": {"summary": "web-v1 has no ready replicas"},
            "startsAt": "2026-10-01T11:00:00Z",
            "endsAt": "2026-10-01T11:05:00Z",
            "fingerprint": "def",
        },
    ],
}


class AlertLinesTest(unittest.TestCase):
    def test_one_json_line_per_alert(self) -> None:
        lines = alert_receiver.alert_lines(NOTIFICATION, now="2026-10-01T12:00:10Z")
        self.assertEqual(len(lines), 2)
        records = [json.loads(line) for line in lines]
        for line in lines:
            self.assertNotIn("\n", line)
        first = records[0]
        self.assertEqual(first["alertname"], "Watchdog")
        self.assertEqual(first["status"], "firing")
        self.assertEqual(first["severity"], "none")
        self.assertEqual(first["receiver"], "alert-log")
        self.assertEqual(first["time"], "2026-10-01T12:00:10Z")
        self.assertEqual(first["labels"]["prometheus"], "monitoring/x")
        self.assertEqual(first["fingerprint"], "abc")
        self.assertIn("Watchdog", first["msg"])
        self.assertEqual(records[1]["status"], "resolved")
        self.assertEqual(records[1]["endsAt"], "2026-10-01T11:05:00Z")

    def test_missing_fields_do_not_fail(self) -> None:
        lines = alert_receiver.alert_lines({"alerts": [{}]}, now="2026-10-01T12:00:00Z")
        record = json.loads(lines[0])
        self.assertEqual(record["alertname"], "")
        self.assertEqual(record["labels"], {})

    def test_not_a_notification(self) -> None:
        for payload in ([], {"alerts": "x"}, {"alerts": [1]}):
            with self.assertRaises(ValueError):
                alert_receiver.alert_lines(payload, now="2026-10-01T12:00:00Z")


class ServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.output = io.StringIO()
        self.server = alert_receiver.make_server("127.0.0.1", 0, self.output)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def request(self, method: str, path: str, body: bytes | None = None) -> int:
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=body,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return int(resp.status)
        except urllib.error.HTTPError as err:
            return int(err.code)

    def test_post_writes_lines(self) -> None:
        status = self.request("POST", "/alerts", json.dumps(NOTIFICATION).encode())
        self.assertEqual(status, 200)
        lines = self.output.getvalue().splitlines()
        self.assertEqual([json.loads(line)["alertname"] for line in lines], ["Watchdog", "AppDown"])

    def test_bad_requests(self) -> None:
        self.assertEqual(self.request("POST", "/alerts", b"{not json"), 400)
        self.assertEqual(self.request("POST", "/other", b"{}"), 404)
        self.assertEqual(self.request("GET", "/alerts"), 404)
        self.assertEqual(self.output.getvalue(), "")

    def test_bad_content_length(self) -> None:
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as conn:
            conn.sendall(b"POST /alerts HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n")
            reply = conn.recv(1024)
        self.assertTrue(reply.startswith(b"HTTP/1.0 400"), reply)
        self.assertEqual(self.output.getvalue(), "")

    def test_healthz(self) -> None:
        self.assertEqual(self.request("GET", "/healthz"), 200)


if __name__ == "__main__":
    unittest.main()
