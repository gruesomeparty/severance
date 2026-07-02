#!/usr/bin/env python3
"""Canned OAuth-usage endpoint for Severance Tier-2 tests (PRD §9.2).

Binds an ephemeral port on 127.0.0.1, writes the chosen port to argv[1], then
serves fixed responses by path:

    /good       200  valid usage JSON
    /extra      200  usage JSON with extra_usage.used_credits > 0
    /malformed  200  invalid JSON body
    /401        401  "OAuth authentication is currently not supported"
    /timeout    ...  sleeps longer than the client timeout

No network egress, no secrets. Never talks to Anthropic.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GOOD = (
    '{"five_hour":{"utilization":37.0,"resets_at":"2026-02-08T04:59:59+00:00"},'
    '"seven_day":{"utilization":26.0,"resets_at":"2026-02-12T14:59:59+00:00"},'
    '"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}'
)
EXTRA = (
    '{"five_hour":{"utilization":12.0,"resets_at":"2026-02-08T04:59:59+00:00"},'
    '"seven_day":{"utilization":8.0,"resets_at":"2026-02-12T14:59:59+00:00"},'
    '"extra_usage":{"is_enabled":true,"monthly_limit":100,"used_credits":12.5,"utilization":12.5}}'
)
RESPONSES = {
    "/good": (200, GOOD),
    "/extra": (200, EXTRA),
    "/malformed": (200, "{ this is not json"),
    "/401": (401, "OAuth authentication is currently not supported"),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/timeout":
            time.sleep(5)
        status, body = RESPONSES.get(self.path, (404, "not found"))
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):  # silence access log
        pass


def main():
    port_file = sys.argv[1]
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(port_file, "w", encoding="utf-8") as fh:
        fh.write(str(httpd.server_address[1]))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
