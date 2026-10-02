"""Alertmanager webhook receiver that writes every alert to stdout.

Alertmanager POSTs notifications (a group of alerts) to /alerts; every alert
of a notification becomes one JSON line on stdout. Fluentd collects the
line like any other container log and ships it to VictoriaLogs, so the
alerts can be searched there (for example `alertname:Watchdog`).

Standard library only; listens on 0.0.0.0:<PORT> (default 8080).
GET /healthz answers 200 for the probes.
"""

import json
import os
import sys
from datetime import UTC, datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, TextIO

ALERTS_PATH = "/alerts"
HEALTH_PATH = "/healthz"
MAX_BODY_BYTES = 1 << 20
SOCKET_TIMEOUT_SECONDS = 15


def _text_map(value: Any) -> dict[str, str]:
    """Labels or annotations as a str -> str mapping ({} if absent)."""
    if not isinstance(value, dict):
        return {}
    return {str(key): str(val) for key, val in value.items()}


def alert_lines(notification: Any, now: str) -> list[str]:
    """One compact JSON line per alert of an Alertmanager notification.

    Raises ValueError if the payload is not a webhook notification.
    """
    if not isinstance(notification, dict) or not isinstance(notification.get("alerts"), list):
        raise ValueError("not an Alertmanager notification: no alerts list")
    lines = []
    for alert in notification["alerts"]:
        if not isinstance(alert, dict):
            raise ValueError("not an Alertmanager notification: alert is not an object")
        labels = _text_map(alert.get("labels"))
        annotations = _text_map(alert.get("annotations"))
        status = str(alert.get("status", notification.get("status", "")))
        alertname = labels.get("alertname", "")
        summary = annotations.get("summary", "")
        record = {
            "time": now,
            "msg": f"alert {status} {alertname}: {summary}".rstrip(": "),
            "log_type": "alert",
            "receiver": str(notification.get("receiver", "")),
            "status": status,
            "alertname": alertname,
            "severity": labels.get("severity", ""),
            "labels": labels,
            "annotations": annotations,
            "startsAt": str(alert.get("startsAt", "")),
            "endsAt": str(alert.get("endsAt", "")),
            "fingerprint": str(alert.get("fingerprint", "")),
            "group_key": str(notification.get("groupKey", "")),
        }
        lines.append(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    return lines


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def make_server(host: str, port: int, output: TextIO) -> ThreadingHTTPServer:
    """HTTP server writing the alerts it receives to `output`."""

    class Handler(BaseHTTPRequestHandler):
        server_version = "alert-receiver"
        sys_version = ""
        # Seconds a client may stay silent before the connection is dropped.
        timeout = SOCKET_TIMEOUT_SECONDS

        def _reply(self, status: HTTPStatus) -> None:
            body = f"{status.phrase}\n".encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802 (name required by BaseHTTPRequestHandler)
            self._reply(HTTPStatus.OK if self.path == HEALTH_PATH else HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            if self.path != ALERTS_PATH:
                self._reply(HTTPStatus.NOT_FOUND)
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            if length <= 0 or length > MAX_BODY_BYTES:
                self._reply(HTTPStatus.BAD_REQUEST)
                return
            try:
                lines = alert_lines(json.loads(self.rfile.read(length)), _now())
            except ValueError:
                self._reply(HTTPStatus.BAD_REQUEST)
                return
            for line in lines:
                output.write(line + "\n")
            output.flush()
            self._reply(HTTPStatus.OK)

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            """Requests are not logged: stdout carries only the alerts."""

    return ThreadingHTTPServer((host, port), Handler)


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = make_server("0.0.0.0", port, sys.stdout)  # noqa: S104 (in-cluster Service)
    print(json.dumps({"time": _now(), "msg": f"alert receiver listening on :{port}"}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
