#!/usr/bin/env python3
"""End-to-end verification for subscription fetching.

Re-runnable by a reviewer: python3 scripts/verify.py

The live subscription check at the end is optional: set the N2O_TEST_SUB_URL
environment variable to a reachable subscription URL to enable it. When the
variable is unset or empty the live check is skipped and only the local
fixture checks run.
"""

import base64
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "zig-out" / "bin" / "node2outbound"
LIVE_URL = os.environ.get("N2O_TEST_SUB_URL", "").strip()

FIXTURE = (
    "# ???\n"
    "proxies:\n"
    "  - name: sub-node\n"
    "    type: ss\n"
    "    server: 1.2.3.4\n"
    "    port: 8388\n"
    "    cipher: aes-256-gcm\n"
    "    password: pw\n"
).encode()

CHALLENGE = (
    "<!DOCTYPE html><html><head><title>Just a moment...</title></head>"
    "<body><div class=\"cf-chl\">Checking your browser before accessing.</div>"
    "<script src=\"/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1\"></script>"
    "</body></html>"
).encode()


def yaml_with_name(name: str) -> bytes:
    escaped = name.replace("\\", "\\\\").replace('"', '\\"')
    return (
        "proxies:\n"
        f'  - name: "{escaped}"\n'
        "    type: ss\n"
        "    server: 1.2.3.4\n"
        "    port: 8388\n"
        "    cipher: aes-256-gcm\n"
        "    password: pw\n"
    ).encode()


class Handler(BaseHTTPRequestHandler):
    ua_log: list[list[str]] = []

    def log_message(self, *args):
        pass

    def send_body(self, status: int, body: bytes, content_type: str = "application/octet-stream"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/plain":
            self.send_body(200, FIXTURE)
        elif path == "/base64":
            self.send_body(200, base64.b64encode(FIXTURE))
        elif path == "/urlsafe":
            self.send_body(200, base64.urlsafe_b64encode(FIXTURE).rstrip(b"="))
        elif path == "/userinfo":
            self.send_body(200, b"upload=1; download=2; total=3; expire=4\n" + base64.b64encode(FIXTURE))
        elif path == "/redirect":
            port = self.server.server_address[1]
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{port}/plain")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/challenge":
            self.send_body(200, CHALLENGE, "text/html; charset=UTF-8")
        elif path == "/forbidden":
            self.send_body(403, b"", "text/html; charset=UTF-8")
        elif path == "/echo-ua":
            values = self.headers.get_all("User-Agent") or []
            Handler.ua_log.append(values)
            self.send_body(200, yaml_with_name(values[0] if values else "MISSING"))
        elif path == "/header":
            self.send_body(200, yaml_with_name(self.headers.get("X-Token", "MISSING")))
        else:
            self.send_body(404, b"not found", "text/plain")


def run(args, stdin=None, timeout=90):
    return subprocess.run(
        [str(BIN), *args],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=ROOT,
    )


def check(name, condition, detail=""):
    if not condition:
        print(f"FAIL {name}: {detail}", file=sys.stderr)
        raise SystemExit(1)
    print(f"PASS {name}")


def expect_outbounds(name, proc, expected_tag=None):
    check(
        name,
        proc.returncode == 0,
        f"exit={proc.returncode} stderr={proc.stderr[:400]!r}",
    )
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        check(name, False, f"stdout is not JSON: {exc} head={proc.stdout[:200]!r}")
        return
    check(name, isinstance(data, list) and len(data) > 0, f"output={data!r}")
    if expected_tag is not None:
        check(
            name,
            data[0].get("tag") == expected_tag,
            f"tag={data[0].get('tag')!r} expected={expected_tag!r}",
        )
    return data


def main():
    for command in (["zig", "build", "test"], ["zig", "build", "-Doptimize=ReleaseSafe"]):
        proc = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=300)
        check(
            " ".join(command),
            proc.returncode == 0,
            f"exit={proc.returncode} stdout={proc.stdout[-800:]!r} stderr={proc.stderr[-800:]!r}",
        )

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"

    try:
        for path in ("/plain", "/base64", "/urlsafe", "/userinfo", "/redirect"):
            expect_outbounds(f"fetch {path}", run(["-u", base + path]), "sub-node")

        Handler.ua_log.clear()
        expect_outbounds(
            "default User-Agent",
            run(["-u", base + "/echo-ua"]),
            "sing-box 1.14.0",
        )
        check(
            "single User-Agent header",
            len(Handler.ua_log) == 1 and len(Handler.ua_log[0]) == 1,
            f"observed User-Agent headers: {Handler.ua_log!r}",
        )

        expect_outbounds(
            "--user-agent override",
            run(["-u", base + "/echo-ua", "-A", "clash-verge/2.0"]),
            "clash-verge/2.0",
        )
        expect_outbounds(
            "--header passthrough",
            run(["-u", base + "/header", "--header", "X-Token: abc"]),
            "abc",
        )

        challenge = run(["-u", base + "/challenge"])
        check("challenge is an error", challenge.returncode == 1, f"exit={challenge.returncode}")
        check(
            "challenge names the mitigation",
            "人机验证" in challenge.stderr and "--user-agent" in challenge.stderr,
            f"stderr={challenge.stderr!r}",
        )

        forbidden = run(["-u", base + "/forbidden"])
        check("403 is an error", forbidden.returncode == 1, f"exit={forbidden.returncode}")
        check("403 reports status", "403" in forbidden.stderr, f"stderr={forbidden.stderr!r}")

        conflict = run(["-i", "does-not-matter.yaml", "-u", base + "/plain"])
        check(
            "-i and -u conflict",
            conflict.returncode == 1 and conflict.stderr.strip() != "",
            f"exit={conflict.returncode} stderr={conflict.stderr!r}",
        )

        expect_outbounds("stdin still works", run([], stdin=FIXTURE.decode()), "sub-node")

        if LIVE_URL:
            live = run(["-u", LIVE_URL], timeout=120)
            expect_outbounds("live subscription", live)
        else:
            print("SKIP live subscription (set N2O_TEST_SUB_URL to enable)")
    finally:
        server.shutdown()
        server.server_close()

    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
