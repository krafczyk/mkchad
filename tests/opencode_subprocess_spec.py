#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "lua" / "configs" / "opencode.lua"
WORKER = ROOT / "tests" / "opencode_subprocess_worker.lua"
FIXTURE = ROOT / "tests" / "bounded_subprocess_fixture.py"
BASE = Path("/tmp/opencode-mkchad/bounded-subprocess")


def wait_path(path: Path, timeout: float = 5) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path}")


def worker(env: dict[str, str], mode: str, control: Path) -> subprocess.Popen:
    return subprocess.Popen(
        ["nvim", "--headless", "-u", "NONE", "-l", str(WORKER), str(CONFIG), mode, str(control)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def finish(process: subprocess.Popen, timeout: float = 35) -> None:
    stdout, stderr = process.communicate(timeout=timeout)
    assert process.returncode == 0, stdout + stderr


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="run-", dir=BASE) as temporary:
        root = Path(temporary)
        state = root / "state"
        bin_dir = root / "bin"
        state.mkdir(mode=0o700)
        bin_dir.mkdir(mode=0o700)
        for name in ("opencode", "java", "keytool"):
            target = bin_dir / name
            shutil.copyfile(FIXTURE, target)
            target.chmod(0o755)
        env = os.environ.copy()
        env.update({
            "PATH": str(bin_dir) + os.pathsep + env["PATH"],
            "XDG_STATE_HOME": str(state),
            "NVIM_APPNAME": "mkchad",
            "MKCHAD_SUBPROCESS_BIN": str(bin_dir),
        })

        control = root / "serial.result"
        serial = worker(env, "serial", control)
        finish(serial, 45)
        assert control.read_text().strip() == "passed"
        for marker in root.glob("*.pid"):
            assert not Path(f"/proc/{int(marker.read_text())}").exists(), marker

        holder_control = root / "holder.result"
        holder = worker(env, "holder", holder_control)
        wait_path(Path(str(holder_control) + ".marker"))
        contender_control = root / "contender.result"
        contender = worker(env, "contender", contender_control)
        finish(contender, 5)
        finish(holder, 5)
        assert contender_control.read_text().strip() == "acquired"
        assert holder_control.read_text().strip() == "released"

        shutdown_control = root / "shutdown.result"
        shutdown = worker(env, "shutdown", shutdown_control)
        finish(shutdown, 5)
        shutdown_pid = int(Path(str(shutdown_control) + ".pid").read_text())
        shutdown_proc = Path(f"/proc/{shutdown_pid}")
        deadline = time.monotonic() + 3
        while shutdown_proc.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert not shutdown_proc.exists()
        shutdown_contender = worker(env, "contender", root / "shutdown-contender.result")
        finish(shutdown_contender, 5)


if __name__ == "__main__":
    main()
