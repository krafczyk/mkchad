#!/usr/bin/env python3
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "tests" / "opencode_delayed_contender_spec.lua"
CONFIG = ROOT / "lua" / "configs" / "opencode.lua"
BASE = Path("/tmp/opencode/mkchad-concurrent-startup")


def command(mode: str, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["nvim", "--headless", "-u", "NONE", "-l", str(SPEC), str(CONFIG), mode],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="run-", dir=BASE) as temporary:
        root = Path(temporary)
        state_root, results = root / "state", root / "results"
        state_root.mkdir(mode=0o700)
        results.mkdir(mode=0o700)
        env = os.environ.copy()
        env.update({
            "XDG_STATE_HOME": str(state_root),
            "NVIM_APPNAME": "mkchad",
            "MKCHAD_OPENCODE_RESULT": str(results / "result"),
            "MKCHAD_OPENCODE_EXPECT_FALLBACK": "1",
        })
        setup = command("setup", env)
        assert setup.returncode == 0, setup.stderr

        occupied = socket.socket()
        occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            occupied.bind(("127.0.0.1", 4096))
            occupied.listen()
        except OSError:
            occupied.close()
            occupied = None
        workers = [
            subprocess.Popen(
                ["nvim", "--headless", "-u", "NONE", "-l", str(SPEC), str(CONFIG), "worker"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _ in range(2)
        ]
        for worker in workers:
            _, stderr = worker.communicate(timeout=60)
            assert worker.returncode == 0, stderr
        if occupied:
            occupied.close()

        records = [path.read_text().splitlines() for path in results.iterdir()]
        assert len(records) == 2 and records[0] == records[1], records
        state_files = list(state_root.glob("mkchad/opencode/*/state.json"))
        assert len(state_files) == 1
        state = json.loads(state_files[0].read_text())
        assert state["schema"] == 2 and state["port"] != 4096
        assert records[0] == [state["generation"], str(state["proxy"]["pid"]), str(state["backend"]["pid"])]
        for role in ("proxy", "backend"):
            assert Path(f"/proc/{state[role]['pid']}").exists()

        # Both originating Neovim processes exited; the detached pair remains usable.
        health = subprocess.run(
            ["curl", "--silent", "--show-error", "--cacert", state["ca_path"], "--max-time", "3", state["url"] + "/global/health"],
            capture_output=True,
        )
        assert health.returncode == 0 and b"healthy" in health.stdout
        cleanup = command("cleanup", env)
        assert cleanup.returncode == 0, cleanup.stderr


if __name__ == "__main__":
    main()
