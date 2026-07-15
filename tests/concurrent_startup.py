#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
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


def run_case(root: Path, direct: bool) -> None:
    root.mkdir(mode=0o700)
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
    expected_transport = "loopback-http" if direct else "tls-proxy"
    if direct:
        server_config = root / "opencode-server.json"
        server_config.write_text(json.dumps({"tls_proxy": False}))
        server_config.chmod(0o600)
        env["MKCHAD_OPENCODE_SERVER_CONFIG"] = str(server_config)
    workers: list[subprocess.Popen] = []
    occupied = None
    cleaned = False
    try:
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

        records = [path.read_text().splitlines() for path in results.iterdir()]
        assert len(records) == 2 and records[0] == records[1], records
        state_files = list(state_root.glob("mkchad/opencode/*/state.json"))
        assert len(state_files) == 1
        state = json.loads(state_files[0].read_text())
        assert state["schema"] == 3 and state["transport"] == expected_transport and state["port"] != 4096
        expected_record = [state["generation"], str(state["backend"]["pid"])]
        roles = ["backend"]
        if not direct:
            expected_record.insert(1, str(state["proxy"]["pid"]))
            roles.insert(0, "proxy")
        assert records[0] == expected_record
        for role in roles:
            assert Path(f"/proc/{state[role]['pid']}").exists()

        # Both originating Neovim processes exited; the detached pair remains usable.
        health_command = ["curl", "--silent", "--show-error", "--max-time", "3"]
        if not direct:
            health_command.extend(["--cacert", state["ca_path"]])
        health_command.append(state["url"] + "/global/health")
        health = subprocess.run(health_command, capture_output=True)
        assert health.returncode == 0 and b"healthy" in health.stdout
        cleanup = command("cleanup", env)
        assert cleanup.returncode == 0, cleanup.stderr
        cleaned = True
    finally:
        if occupied:
            occupied.close()
        for worker in workers:
            if worker.poll() is None:
                worker.terminate()
                try:
                    worker.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait(timeout=3)
        if not cleaned:
            cleanup = command("cleanup", env)
            if cleanup.returncode != 0:
                raise AssertionError("failed case cleanup; fixture tree must be preserved: " + cleanup.stderr)


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=BASE))
    try:
        run_case(root / "tls", False)
        run_case(root / "direct", True)
    except Exception as error:
        error.add_note(f"preserved concurrent-startup fixture: {root}")
        raise
    else:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
