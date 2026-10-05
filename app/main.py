"""Minimal drift-lab probe app (stdlib only).

Exposes runtime truth so curl can be compared against what Argo *claims*
the declared state is. Three config sources are intentionally split so
drift in each is independently observable:

  - greeting_env:  ConfigMap value injected as an env var (read once, at
                    process start -- a pod restart is required to pick up
                    a ConfigMap edit).
  - greeting_file: the same ConfigMap mounted as a volume and re-read on
                    every request (kubelet syncs mounted ConfigMaps
                    in-place, usually within ~1 minute, no restart needed).
  - secret_sha256: sha256 of a mounted Secret's value, never the value
                    itself, so this can be committed/shared/pasted safely.
"""
import hashlib
import http.server
import json
import os
import socket

VERSION = os.environ.get("APP_VERSION", "dev")
GREETING_ENV = os.environ.get("GREETING", "")
GREETING_FILE_PATH = "/config/greeting"
SECRET_FILE_PATH = "/secret/value"


def read_file(path: str) -> str:
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except OSError as e:
        return f"<unreadable: {e.strerror}>"


def secret_sha256() -> str:
    try:
        with open(SECRET_FILE_PATH, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError as e:
        return f"<unreadable: {e.strerror}>"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(
            {
                "version": VERSION,
                "greeting_env": GREETING_ENV,
                "greeting_file": read_file(GREETING_FILE_PATH),
                "secret_sha256": secret_sha256(),
                "hostname": socket.gethostname(),
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # keep pod logs quiet; events/diff are the evidence trail


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
