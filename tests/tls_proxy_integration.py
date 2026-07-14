#!/usr/bin/env python3
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PROXY = ROOT / "java" / "MkChadTlsProxy.java"
PLUGIN = Path(os.environ.get("OPENCODE_NVIM_ROOT", "/data1/matthew/Projects/opencode.nvim"))
BASE = Path(os.environ.get("MKCHAD_TLS_TEST_ROOT", "/tmp/opencode/mkchad-tls-proxy"))
PASSWORD = "test-password-file-only"


BACKEND_SOURCE = r'''
import json, os, socket, sys, time
port, log, ready, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(64); open(ready, "w").close()
while True:
  client, _ = s.accept(); client.settimeout(5)
  with client:
    request_count = 0
    while True:
      raw = b""
      try:
        while b"\r\n\r\n" not in raw:
          part = client.recv(4096)
          if not part: break
          raw += part
      except (TimeoutError, ConnectionError): break
      if not raw: break
      head, body = raw.split(b"\r\n\r\n", 1)
      length = 0
      for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"): length = int(line.split(b":", 1)[1])
      while len(body) < length: body += client.recv(length - len(body))
      with open(log, "a") as out: out.write(json.dumps({"head": head.decode("latin1"), "body": body[:length].decode("latin1")}) + "\n")
      target = head.split()[1]
      request_count += 1
      if mode == "preflight-401" and request_count == 1:
        client.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"); continue
      if mode == "chunked":
        client.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n0\r\n\r\n"); break
      if mode == "close":
        client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); break
      if mode == "oversized":
        client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 70000\r\nConnection: keep-alive\r\n\r\n"); break
      if mode == "malformed":
        client.sendall(b"HTTP/1.1 200 OK\r\nBroken\r\nContent-Length: 0\r\n\r\n"); break
      if mode == "timeout":
        time.sleep(5); break
      if mode == "exit-after-preflight":
        payload = b'{"healthy":true}'
        client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(payload)).encode() + b"\r\nConnection: keep-alive\r\n\r\n" + payload)
        raise SystemExit(0)
      if target == b"/event":
        client.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\n\r\ndata: {\"type\":\"server.connected\"}\n\n")
        time.sleep(1)
        client.sendall(b"data: {\"type\":\"server.heartbeat\"}\n\n")
        time.sleep(1)
        break
      payload = b'{"healthy":true}'
      client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(payload)).encode() + b"\r\nConnection: keep-alive\r\n\r\n" + payload)
'''


def run(*args: str) -> None:
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start_time(pid: int) -> str:
    text = Path(f"/proc/{pid}/stat").read_text()
    return text[text.rfind(")") + 2 :].split()[19]


def wait_file(path: Path, timeout: float = 5) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {path}")


def wait_port(port: int, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError(f"timed out waiting for port {port}")


def make_certs(root: Path) -> tuple[Path, Path]:
    password = root / "store.password"
    ca_store, server_store = root / "ca.p12", root / "server.p12"
    ca, csr, leaf = root / "ca.pem", root / "server.csr", root / "server.pem"
    password.write_text(PASSWORD)
    os.chmod(password, 0o600)
    common = ("-storepass:file", str(password))
    run("keytool", "-genkeypair", "-alias", "ca", "-keyalg", "EC", "-groupname", "secp256r1", "-dname", "CN=test CA", "-ext", "bc:c", "-ext", "ku=keyCertSign,cRLSign", "-validity", "2", "-keystore", str(ca_store), "-storetype", "PKCS12", *common, "-noprompt")
    run("keytool", "-exportcert", "-rfc", "-alias", "ca", "-keystore", str(ca_store), *common, "-file", str(ca))
    run("keytool", "-genkeypair", "-alias", "server", "-keyalg", "EC", "-groupname", "secp256r1", "-dname", "CN=127.0.0.1", "-ext", "SAN=IP:127.0.0.1", "-validity", "2", "-keystore", str(server_store), "-storetype", "PKCS12", *common, "-noprompt")
    run("keytool", "-certreq", "-alias", "server", "-keystore", str(server_store), *common, "-file", str(csr))
    run("keytool", "-gencert", "-rfc", "-alias", "ca", "-keystore", str(ca_store), *common, "-infile", str(csr), "-outfile", str(leaf), "-validity", "2", "-ext", "SAN=IP:127.0.0.1", "-ext", "EKU=serverAuth")
    run("keytool", "-importcert", "-alias", "ca", "-keystore", str(server_store), *common, "-file", str(ca), "-noprompt")
    run("keytool", "-importcert", "-alias", "server", "-keystore", str(server_store), *common, "-file", str(leaf), "-noprompt")
    for path in root.iterdir():
        if path.is_file():
            os.chmod(path, 0o600)
    return ca, server_store


def backend(root: Path, port: int, name: str, mode: str = "normal") -> tuple[subprocess.Popen, Path]:
    log, ready = root / f"{name}.jsonl", root / f"{name}.ready"
    process = subprocess.Popen([sys.executable, str(root / "backend.py"), str(port), str(log), str(ready), mode])
    wait_file(ready)
    return process, log


def proxy(root: Path, public: int, internal: int, expected: subprocess.Popen, store: Path, *, boot: str | None = None, start: str | None = None) -> subprocess.Popen:
    command = [
        "java", "--source", "21", str(PROXY),
        "--listen-port", str(public),
        "--backend-port", str(internal),
        "--backend-pid", str(expected.pid),
        "--backend-start", start or start_time(expected.pid),
        "--boot-id", boot or Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "--keystore", str(store),
        "--password-file", str(root / "store.password"),
        "--max-connections", "32",
    ]
    return subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def tls_request(ca: Path, port: int, request: bytes, *, read_until: bytes = b"healthy") -> bytes:
    context = ssl.create_default_context(cafile=str(ca))
    with socket.create_connection(("127.0.0.1", port), timeout=4) as raw:
        with context.wrap_socket(raw, server_hostname="127.0.0.1") as client:
            client.sendall(request)
            response = b""
            while read_until not in response:
                part = client.recv(4096)
                if not part:
                    break
                response += part
            return response


def records(path: Path) -> list[dict[str, str]]:
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def stop(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(3)


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="run-", dir=BASE) as temporary:
        root = Path(temporary)
        os.chmod(root, 0o700)
        (root / "backend.py").write_text(BACKEND_SOURCE)
        ca, store = make_certs(root)
        internal, public = free_port(), free_port()
        service, log = backend(root, internal, "normal")
        relay = proxy(root, public, internal, service, store)
        try:
            wait_port(public)
            attach_env = os.environ.copy()
            attach_env.pop("OPENCODE_SERVER_PASSWORD", None)
            attach_env.pop("OPENCODE_SERVER_USERNAME", None)
            attach_env["NODE_EXTRA_CA_CERTS"] = str(ca)
            attach = subprocess.run(
                ["timeout", "5", "opencode", "attach", f"https://127.0.0.1:{public}", "--dir", str(root)],
                env=attach_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            assert attach.returncode in (0, 1, 124), attach.returncode
            assert len(records(log)) >= 2, "installed opencode attach did not reach the backend through NODE_EXTRA_CA_CERTS"

            no_ca = subprocess.run(["curl", "--silent", "--show-error", "--max-time", "2", f"https://127.0.0.1:{public}/global/health"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            assert no_ca.returncode != 0, "curl trusted the private CA without an explicit CA"
            with_ca = subprocess.run(["curl", "--silent", "--show-error", "--cacert", str(ca), "--max-time", "3", f"https://127.0.0.1:{public}/global/health"], capture_output=True)
            assert with_ca.returncode == 0 and b"healthy" in with_ca.stdout

            subprocess.run(
                [
                    "nvim", "--headless", "-u", "NONE", "-l", str(PLUGIN / "tests" / "curl_tls_spec.lua"),
                    str(PLUGIN), f"https://127.0.0.1:{public}", str(ca),
                ],
                check=True,
                timeout=15,
            )

            secret = b"proxy-client-secret"
            request = b"POST /client HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic credential\r\nContent-Length: " + str(len(secret)).encode() + b"\r\nConnection: close\r\n\r\n" + secret
            assert b"healthy" in tls_request(ca, public, request)
            sse = tls_request(ca, public, b"GET /event HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n", read_until=b"server.heartbeat")
            assert b"server.connected" in sse and b"server.heartbeat" in sse

            health = b"GET /global/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: tls_request(ca, public, health), range(24)))
            assert all(b"healthy" in response for response in results)
            seen = records(log)
            assert any("Authorization: Basic credential" in item["head"] and item["body"] == secret.decode() for item in seen)
            assert any("Authorization: Basic" in item["head"] and "x-opencode-directory:" in item["head"].lower() and "plugin-tls-body" in item["body"] for item in seen)

            auth_internal, auth_public = free_port(), free_port()
            auth_backend, auth_log = backend(root, auth_internal, "preflight-401", "preflight-401")
            auth_proxy = proxy(root, auth_public, auth_internal, auth_backend, store)
            try:
                wait_port(auth_public)
                assert b"healthy" in tls_request(ca, auth_public, request)
                auth_records = records(auth_log)
                assert len(auth_records) == 2
                assert "Authorization:" not in auth_records[0]["head"]
                assert "Authorization: Basic credential" in auth_records[1]["head"]
            finally:
                stop(auth_proxy); stop(auth_backend)

            replacement_port, mismatch_public = free_port(), free_port()
            replacement, replacement_log = backend(root, replacement_port, "replacement-before")
            sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            mismatch = proxy(root, mismatch_public, replacement_port, sleeper, store)
            try:
                wait_port(mismatch_public)
                try:
                    tls_request(ca, mismatch_public, request)
                except (OSError, ssl.SSLError):
                    pass
                time.sleep(0.3)
                captured = records(replacement_log)
                assert len(captured) == 1 and captured[0]["head"].startswith("GET /global/health ")
                assert "Authorization:" not in captured[0]["head"] and secret.decode() not in captured[0]["body"]
            finally:
                stop(mismatch); stop(sleeper); stop(replacement)

            stop(service)
            after, after_log = backend(root, internal, "replacement-after")
            try:
                try:
                    tls_request(ca, public, request)
                except (OSError, ssl.SSLError):
                    pass
                time.sleep(0.3)
                assert records(after_log) == [], "replacement backend received bytes after expected backend death"
            finally:
                stop(after)

            for mode in ("chunked", "close", "oversized", "malformed", "timeout", "exit-after-preflight"):
                invalid_internal, invalid_public = free_port(), free_port()
                invalid_backend, invalid_log = backend(root, invalid_internal, "invalid-" + mode, mode)
                invalid_proxy = proxy(root, invalid_public, invalid_internal, invalid_backend, store)
                try:
                    wait_port(invalid_public)
                    try:
                        tls_request(ca, invalid_public, request)
                    except (OSError, ssl.SSLError):
                        pass
                    captured = records(invalid_log)
                    assert len(captured) == 1 and captured[0]["head"].startswith("GET /global/health "), mode
                    assert "Authorization:" not in captured[0]["head"] and secret.decode() not in captured[0]["body"], mode
                finally:
                    stop(invalid_proxy); stop(invalid_backend)

            identity_sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            try:
                for bad_boot, bad_start in [("not-this-boot", None), (None, "0")]:
                    candidate = proxy(root, free_port(), internal, identity_sleeper, store, boot=bad_boot, start=bad_start)
                    assert candidate.wait(5) != 0, "proxy accepted mismatched boot or PID start identity"
            finally:
                stop(identity_sleeper)
        finally:
            stop(relay); stop(service)


if __name__ == "__main__":
    main()
