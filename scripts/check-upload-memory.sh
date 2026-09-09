#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
swiftc -parse-as-library -O Sources/dBrief/Utilities/MultipartFormData.swift \
    scripts/MultipartUploadMemoryCheck.swift -o "$task_tmp/check-memory"
python3 - "$task_tmp/check-memory" <<'PY'
import http.server
import subprocess
import sys
import threading

class Receiver(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        remaining = int(self.headers.get("Content-Length", "0"))
        received = 0
        while remaining:
            chunk = self.rfile.read(min(64 * 1024, remaining))
            if not chunk:
                break
            received += len(chunk)
            remaining -= len(chunk)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(str(received).encode())

with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    receiver = f"http://127.0.0.1:{server.server_port}/upload"
    try:
        for label, args in [("Preparation", []), ("Preparation + URLSession upload", [receiver])]:
            readings = []
            for size in [8, 512]:
                result = subprocess.run([sys.argv[1], str(size), *args], check=True,
                                        capture_output=True, text=True, timeout=120)
                readings.append(tuple(map(int, result.stdout.split())))
            (small_size, small_rss), (large_size, large_rss) = readings
            mib = 1024 * 1024
            print(f"{label}: {small_size} MiB input = {small_rss / mib:.1f} MiB peak RSS; "
                  f"{large_size} MiB input = {large_rss / mib:.1f} MiB peak RSS")
            print(f"Peak RSS growth: {(large_rss - small_rss) / mib:.1f} MiB")
            # A whole-file read adds ~504 MiB; permit ordinary OS/allocator variance.
            if large_rss - small_rss > 32 * mib:
                sys.exit("FAIL: upload memory scales with audio size")
        print("PASS: upload memory stays bounded and receiver gets every byte")
    finally:
        server.shutdown()
PY
