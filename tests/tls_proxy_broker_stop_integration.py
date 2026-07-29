#!/usr/bin/env python3
"""Broker stop ordering and pidfd-helper failure integration coverage."""

import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
PROXY = ROOT / "java" / "MkChadTlsProxy.java"
JAVA = os.environ["JAVA"]
KEYTOOL = os.environ.get("KEYTOOL", str(Path(JAVA).parent / "keytool"))
BASE = Path(os.environ["MKCHAD_TEST_ROOT"])


BACKEND = r'''#!/usr/bin/env python3
import os, signal, socket, sys, time
port = int(sys.argv[sys.argv.index("--port") + 1])
marker = os.environ.get("MKCHAD_BROKER_BACKEND_PID_MARKER")
if marker: open(marker, "w").write(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", port)); sock.listen(32)
while True:
    client, _ = sock.accept()
    with client:
        raw = b""
        while b"\r\n\r\n" not in raw:
            part = client.recv(4096)
            if not part: break
            raw += part
        if not raw: continue
        target = raw.split(b" ", 2)[1]
        if target == b"/event":
            client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: keep-alive\r\n\r\nserver.connected")
            time.sleep(30)
        else:
            client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok")
'''

HELPER = r'''
import json, os, signal, sys, time
request = json.load(sys.stdin)
marker = os.environ["MKCHAD_BROKER_HELPER_MARKER"]
with open(marker, "a") as out:
    out.write(request["signal"] + ":" + str(request["process"]["pid"]) + "\n")
mode = os.environ.get("MKCHAD_BROKER_HELPER_MODE", "kill")
if mode == "timeout": time.sleep(10)
if mode == "stdout-overflow": sys.stdout.write("x" * 65537); sys.stdout.flush(); raise SystemExit(7)
if mode == "stderr-overflow": sys.stderr.write("x" * 65537); sys.stderr.flush(); raise SystemExit(7)
if mode == "nonzero": sys.stderr.write("helper nonzero refusal"); raise SystemExit(7)
if mode == "unsupported": sys.stderr.write("pidfd unsupported"); raise SystemExit(7)
if mode == "post-open-mismatch": sys.stderr.write("post-open identity mismatch"); raise SystemExit(7)
if mode == "term-refusal" and request["signal"] == "SIGTERM": sys.stderr.write("TERM refusal"); raise SystemExit(7)
if mode == "kill-refusal" and request["signal"] == "SIGKILL": sys.stderr.write("KILL refusal"); raise SystemExit(7)
if mode == "unconfirmed": raise SystemExit(0)
if mode in ("kill", "kill-refusal") and request["signal"] == "SIGKILL": os.kill(request["process"]["pid"], signal.SIGKILL)
raise SystemExit(0)
'''


def run(*args: str) -> None:
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def free_port() -> int:
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        return candidate.getsockname()[1]


def wait_for(predicate, description: str, timeout: float = 5) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {description}")


def make_certs(root: Path) -> tuple[Path, Path, Path]:
    password = root / "store.password"
    ca_store, server_store = root / "ca.p12", root / "server.p12"
    ca, csr, leaf = root / "ca.pem", root / "server.csr", root / "server.pem"
    password.write_text("broker-stop-test-password")
    os.chmod(password, 0o600)
    common = ("-storepass:file", str(password))
    run(KEYTOOL, "-genkeypair", "-alias", "ca", "-keyalg", "EC", "-groupname", "secp256r1", "-dname", "CN=broker test CA", "-ext", "bc:c", "-ext", "ku=keyCertSign,cRLSign", "-validity", "2", "-keystore", str(ca_store), "-storetype", "PKCS12", *common, "-noprompt")
    run(KEYTOOL, "-exportcert", "-rfc", "-alias", "ca", "-keystore", str(ca_store), *common, "-file", str(ca))
    run(KEYTOOL, "-genkeypair", "-alias", "server", "-keyalg", "EC", "-groupname", "secp256r1", "-dname", "CN=127.0.0.1", "-ext", "SAN=IP:127.0.0.1", "-validity", "2", "-keystore", str(server_store), "-storetype", "PKCS12", *common, "-noprompt")
    run(KEYTOOL, "-certreq", "-alias", "server", "-keystore", str(server_store), *common, "-file", str(csr))
    run(KEYTOOL, "-gencert", "-rfc", "-alias", "ca", "-keystore", str(ca_store), *common, "-infile", str(csr), "-outfile", str(leaf), "-validity", "2", "-ext", "SAN=IP:127.0.0.1", "-ext", "EKU=serverAuth")
    run(KEYTOOL, "-importcert", "-alias", "ca", "-keystore", str(server_store), *common, "-file", str(ca), "-noprompt")
    run(KEYTOOL, "-importcert", "-alias", "server", "-keystore", str(server_store), *common, "-file", str(leaf), "-noprompt")
    for path in root.iterdir():
        if path.is_file():
            os.chmod(path, 0o600)
    return ca, server_store, password


def exchange(control: Path, operation: str, generation: str, *, allow_missing: bool = False) -> dict | None:
    request = json.dumps(
        {"protocol": 1, "operation": operation, "generation": generation, "nonce": operation + "-nonce"},
        separators=(",", ":"),
    ).encode()
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(10)
        deadline = time.monotonic() + 5
        while True:
            try:
                channel.connect(str(control))
                break
            except ConnectionRefusedError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.01)
        channel.sendall(struct.pack(">I", len(request)) + request)
        channel.shutdown(socket.SHUT_WR)
        try:
            header = channel.recv(4)
        except TimeoutError:
            header = b""
        if not header and allow_missing:
            return None
        assert len(header) == 4, "broker omitted a required control response"
        length = struct.unpack(">I", header)[0]
        body = b""
        while len(body) < length:
            part = channel.recv(length - len(body))
            assert part, "broker truncated a control response"
            body += part
        return json.loads(body)


def start_broker(root: Path, helper_mode: str, hook: str | None = None) -> tuple[subprocess.Popen, Path, str, Path, Path]:
    root.mkdir(mode=0o700)
    backend = root / "backend.py"
    helper = root / "helper.py"
    proxy_source = root / "MkChadTlsProxy.java"
    log = root / "backend.log"
    backend.write_text(BACKEND)
    helper.write_text(HELPER)
    proxy_source.write_bytes(PROXY.read_bytes())
    log.touch()
    log.chmod(0o600)
    ca, store, password = make_certs(root)
    for path in (backend, helper):
        path.chmod(0o700)
    control = root / "control.sock"
    hooks = root / "hooks"
    hooks.mkdir(mode=0o700)
    if hook:
        (hooks / f"{hook}.enabled").touch()
    marker = root / "helper.marker"
    generation = "broker-stop-generation"
    command = [
        JAVA,
        f"-Dmkchad.proxy.test-hook-dir={hooks}",
        "--source", "21", str(proxy_source), "--broker",
        "--state-root", str(root), "--control", str(control), "--generation", generation,
        "--boot-id", Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "--backend-executable", str(backend), "--backend-version", "broker-stop-test",
        "--backend-port", str(free_port()), "--listen-port", str(free_port()),
        "--keystore", str(store), "--password-file", str(password), "--max-connections", "8",
        "--backend-log", str(log), "--pidfd-python", str(Path(sys.executable).resolve()), "--pidfd-helper", str(helper),
    ]
    environment = os.environ | {
        "MKCHAD_BROKER_HELPER_MODE": helper_mode,
        "MKCHAD_BROKER_HELPER_MARKER": str(marker),
        "MKCHAD_BROKER_BACKEND_PID_MARKER": str(root / "backend.pid"),
    }
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(control.exists, "broker control socket")
    except AssertionError:
        stdout, stderr = process.communicate(timeout=1)
        raise AssertionError(f"broker did not bind control: {stdout}{stderr}") from None
    try:
        activation = exchange(control, "activate", generation)
    except OSError:
        activation = None
    if activation is None or activation.get("phase") != "running":
        raise AssertionError(f"broker activation failed: {activation!r}; backend log: {log.read_text()}")
    return process, control, generation, ca, marker


def cleanup_broker(process: subprocess.Popen, root: Path, backend_pid: int) -> None:
    if process.poll() is None:
        process.kill()
        process.wait(5)
    try:
        os.kill(backend_pid, 9)
    except ProcessLookupError:
        pass


def frozen_asset_case(root: Path, asset: str) -> None:
    process, control, generation, _, _ = start_broker(root, "kill")
    running = exchange(control, "status", generation)
    assert running and running["phase"] == "running"
    backend_pid = running["backend"]["pid"]
    target = root / asset
    replacement = root / f"{asset}.replacement"
    if asset == "helper.py":
        replacement.write_text(
            "import os\nopen(os.environ['MKCHAD_REPLACEMENT_HELPER_MARKER'], 'w').write('executed')\n"
        )
        replacement.chmod(0o700)
        marker = root / "replacement-helper.executed"
        os.environ["MKCHAD_REPLACEMENT_HELPER_MARKER"] = str(marker)
    else:
        replacement.write_bytes(target.read_bytes())
    os.replace(replacement, target)
    result = exchange(control, "stop" if asset == "helper.py" else "status", generation, allow_missing=True)
    assert result is None, f"replaced live {asset} retained broker authority"
    if asset == "helper.py":
        assert not marker.exists(), "replacement pidfd helper executed"
        os.environ.pop("MKCHAD_REPLACEMENT_HELPER_MARKER", None)
    cleanup_broker(process, root, backend_pid)


def activation_failure_case(root: Path) -> None:
    occupied = socket.socket()
    occupied.bind(("127.0.0.1", 0))
    occupied.listen(1)
    public_port = occupied.getsockname()[1]
    root.mkdir(mode=0o700)
    backend, helper, source = root / "backend.py", root / "helper.py", root / "MkChadTlsProxy.java"
    log, marker = root / "backend.log", root / "helper.marker"
    backend.write_text(BACKEND)
    helper.write_text(HELPER)
    source.write_bytes(PROXY.read_bytes())
    log.touch(mode=0o600)
    _, store, password = make_certs(root)
    backend.chmod(0o700)
    helper.chmod(0o700)
    control, generation = root / "control.sock", "activation-failure-generation"
    environment = os.environ | {
        "MKCHAD_BROKER_HELPER_MODE": "kill",
        "MKCHAD_BROKER_HELPER_MARKER": str(marker),
        "MKCHAD_BROKER_BACKEND_PID_MARKER": str(root / "backend.pid"),
    }
    command = [
        JAVA, "--source", "21", str(source), "--broker", "--state-root", str(root),
        "--control", str(control), "--generation", generation, "--boot-id",
        Path("/proc/sys/kernel/random/boot_id").read_text().strip(), "--backend-executable", str(backend),
        "--backend-version", "activation-failure-test", "--backend-port", str(free_port()),
        "--listen-port", str(public_port), "--keystore", str(store), "--password-file", str(password),
        "--max-connections", "8", "--backend-log", str(log), "--pidfd-python",
        str(Path(sys.executable).resolve()), "--pidfd-helper", str(helper),
    ]
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_for(control.exists, "activation-failure control socket")
    results: list[dict | None] = []
    activation = threading.Thread(target=lambda: results.append(exchange(control, "activate", generation)))
    activation.start()
    wait_for((root / "backend.pid").exists, "activation-failure backend pid")
    backend_pid = int((root / "backend.pid").read_text())
    activation.join(10)
    assert not activation.is_alive() and len(results) == 1
    result = results[0]
    assert result and result["phase"] == "activation-failed", result
    wait_for(lambda: not Path(f"/proc/{backend_pid}").exists(), "activation-failure backend cleanup")
    assert exchange(control, "status", generation)["phase"] == "activation-failed"
    occupied.close()
    process.kill()
    process.wait(5)


def active_tls(ca: Path, port: int, target: str) -> tuple[threading.Thread, threading.Event]:
    done = threading.Event()
    context = ssl.create_default_context(cafile=str(ca))

    def request() -> None:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname="127.0.0.1") as client:
                    client.settimeout(5)
                    client.sendall(f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n".encode())
                    client.recv(1024)
        except (OSError, ssl.SSLError):
            pass
        finally:
            done.set()

    thread = threading.Thread(target=request)
    thread.start()
    return thread, done


def broker_port(process: subprocess.Popen) -> int:
    arguments = Path(f"/proc/{process.pid}/cmdline").read_bytes().split(b"\0")
    index = arguments.index(b"--listen-port")
    return int(arguments[index + 1])


def stop_async(control: Path, generation: str) -> tuple[threading.Thread, list[dict | None]]:
    result: list[dict | None] = []
    thread = threading.Thread(target=lambda: result.append(exchange(control, "stop", generation, allow_missing=True)))
    thread.start()
    return thread, result


def resume(hooks: Path, name: str) -> None:
    (hooks / f"{name}.resume").touch()


def race_case(root: Path, hook: str, target: str) -> None:
    process, control, generation, ca, marker = start_broker(root, "kill", hook)
    hooks = root / "hooks"
    (hooks / "pidfd-signal.enabled").touch()
    request, request_done = active_tls(ca, broker_port(process), target)
    wait_for(lambda: (hooks / f"{hook}.reached").exists(), hook)
    stopper, result = stop_async(control, generation)
    time.sleep(0.2)
    assert not (hooks / "pidfd-signal.reached").exists(), f"{hook} allowed pidfd signaling before quiescence"
    resume(hooks, hook)
    wait_for(lambda: (hooks / "pidfd-signal.reached").exists(), "pidfd marker")
    assert request_done.wait(2), f"{hook} left an accepted relay active at pidfd signaling"
    assert not marker.exists(), f"{hook} dispatched pidfd before the test released the signal marker"
    resume(hooks, "pidfd-signal")
    stopper.join(8)
    request.join(2)
    assert not stopper.is_alive() and len(result) == 1 and result[0] is not None, result
    assert result[0]["operation"] == "stop" and result[0]["generation"] == generation and result[0]["phase"] == "stopped", result
    process.wait(8)
    assert process.returncode == 0 and not control.exists(), f"{hook} did not reach terminal broker cleanup"


def helper_case(root: Path, mode: str, expected_signals: list[str]) -> None:
    process, control, generation, _, marker = start_broker(root, mode)
    result = exchange(control, "stop", generation, allow_missing=True)
    assert result is None, f"{mode} emitted a final receipt after helper failure"
    wait_for(marker.exists, f"{mode} helper invocation", timeout=5)
    signals = [line.split(":", 1)[0] for line in marker.read_text().splitlines()]
    assert signals == expected_signals, f"{mode} helper sequence was {signals!r}"
    assert control.exists() and process.poll() is None, f"{mode} lost private stopping authority"
    assert exchange(control, "status", generation)["phase"] == "stopping", f"{mode} did not remain stopping"
    backend_pid = int(marker.read_text().split(":", 1)[1].splitlines()[0])
    process.kill()
    process.wait(5)
    try:
        os.kill(backend_pid, 9)
    except ProcessLookupError:
        pass


def main() -> None:
    if BASE.exists():
        raise AssertionError(f"test root must be fresh: {BASE}")
    BASE.mkdir(parents=True, mode=0o700)
    for hook, target in (("accept-return", "/health"), ("relay-registered", "/health"), ("backend-connect", "/health"), ("relay-removal", "/event")):
        race_case(BASE / hook, hook, target)
    activation_failure_case(BASE / "activation-failure")
    frozen_asset_case(BASE / "replaced-source", "MkChadTlsProxy.java")
    frozen_asset_case(BASE / "replaced-backend", "backend.py")
    frozen_asset_case(BASE / "replaced-helper", "helper.py")
    for mode, signals in (
        ("timeout", ["SIGTERM"]), ("stdout-overflow", ["SIGTERM"]), ("stderr-overflow", ["SIGTERM"]),
        ("nonzero", ["SIGTERM"]), ("unsupported", ["SIGTERM"]), ("post-open-mismatch", ["SIGTERM"]),
        ("term-refusal", ["SIGTERM"]), ("kill-refusal", ["SIGTERM", "SIGKILL"]), ("unconfirmed", ["SIGTERM", "SIGKILL"]),
    ):
        helper_case(BASE / mode, mode, signals)


if __name__ == "__main__":
    main()
