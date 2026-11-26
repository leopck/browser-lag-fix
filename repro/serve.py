#!/usr/bin/env python3
"""Serves repro/probe.html on http://127.0.0.1:<port>/ (a secure context, as OPFS requires)
and appends the JSON results the page POSTs to a results file.

Usage:
    python repro/serve.py [--port 8765] [--results results.jsonl]
Then open http://127.0.0.1:8765/probe.html in the browser under test and watch the free space
of the drive that holds the browser profile (e.g. Task Manager > Performance > Disk).
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.server
import json
import os


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--results", default="results.jsonl")
    args = ap.parse_args()
    results_path = os.path.abspath(args.results)
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802 (http.server naming)
            if self.path != "/result":
                self.send_error(404)
                return
            length = min(int(self.headers.get("Content-Length", 0)), 1_000_000)
            records = json.loads(self.rfile.read(length))
            stamp = dt.datetime.now().isoformat(timespec="seconds")
            with open(results_path, "a", encoding="utf-8") as f:
                for r in records:
                    f.write(json.dumps({"run": stamp, **r}) + "\n")
            print(f"[{stamp}] {len(records)} records -> {results_path}")
            for r in records:
                print("   ", json.dumps(r))
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_args) -> None:
            pass

    print(f"Open http://127.0.0.1:{args.port}/probe.html  (Ctrl+C to stop)")
    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
