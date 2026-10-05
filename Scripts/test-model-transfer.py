#!/usr/bin/env python3
"""Exercise production progress, cancellation, resume and validation over real HTTP."""
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
class Handler(http.server.BaseHTTPRequestHandler):
    resumed_requests = []

    def do_GET(self):
        total = 2 * 1024 * 1024
        if self.path.endswith("missing"):
            self.send_error(404)
            return
        start = int(self.headers.get("Range", "bytes=0-").split("=")[1].split("-")[0])
        if start:
            self.resumed_requests.append(start)
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(total - start))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{total - 1}/{total}")
        self.send_header("ETag", '"probe"')
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        try:
            for offset in range(start, total, 32768):
                self.wfile.write(b"x" * min(32768, total - offset))
                self.wfile.flush()
                time.sleep(.025)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix="podskipper-transfer-") as directory:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        binary = str(Path(directory) / "probe")
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Services/CoreAIModelDownload.swift"),
                        str(ROOT / "Tools/ModelTransferProbe.swift"), "-o", binary], check=True)
        subprocess.run([binary, f"http://127.0.0.1:{server.server_port}/weights"], check=True, timeout=30)
        assert Handler.resumed_requests, "Resume restarted from zero instead of using Range"
        print("PASS: HTTP Range resume offsets", Handler.resumed_requests)
    finally:
        server.shutdown()
        server.server_close()
