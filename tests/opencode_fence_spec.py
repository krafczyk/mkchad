#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "lua" / "configs" / "opencode.lua"
WORKER = ROOT / "tests" / "opencode_fence_worker.lua"
BASE = Path("/tmp/opencode-mkchad/fence")


def wait_path(path: Path, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path}")


def process_record(pid: int, executable: Path, log: Path) -> dict:
    stat_text = Path(f"/proc/{pid}/stat").read_text()
    start_time = stat_text[stat_text.rindex(")") + 2 :].split()[19]
    argv = [os.fsdecode(value) for value in Path(f"/proc/{pid}/cmdline").read_bytes()[:-1].split(b"\0")]
    runtime = os.stat(f"/proc/{pid}/exe")
    launch = executable.stat()
    return {
        "pid": pid,
        "port": 55001,
        "argv": argv,
        "process_executable": os.readlink(f"/proc/{pid}/exe"),
        "process_executable_dev": str(runtime.st_dev),
        "process_executable_ino": str(runtime.st_ino),
        "executable": str(executable),
        "executable_dev": str(launch.st_dev),
        "executable_ino": str(launch.st_ino),
        "start_time": start_time,
        "local_version": "fence-test",
        "log": str(log),
    }


def run_worker(env: dict[str, str], mode: str, control: Path, input_path: Path | None = None) -> subprocess.Popen:
    command = ["nvim", "--headless", "-u", "NONE", "-l", str(WORKER), str(CONFIG), mode, str(control)]
    if input_path:
        command.append(str(input_path))
    return subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def finish(worker: subprocess.Popen, timeout: float = 10) -> None:
    stdout, stderr = worker.communicate(timeout=timeout)
    assert worker.returncode == 0, stdout + stderr


def reap_killed(worker: subprocess.Popen) -> None:
    worker.communicate(timeout=10)
    assert worker.returncode is not None and worker.returncode != 0


def expire_lease(state_root: Path) -> None:
    owner_path = state_root / "startup.lock" / "owner.json"
    owner = json.loads(owner_path.read_text())
    lease_path = state_root / "startup.lock" / f"lease-{owner['token']}.json"
    lease = json.loads(lease_path.read_text())
    lease["renewed_monotonic_ms"] = 1
    lease["deadline_monotonic_ms"] = 2
    lease_path.write_text(json.dumps(lease))
    lease_path.chmod(0o600)


def blocked_contender(env: dict[str, str], control: Path) -> None:
    contender = run_worker(env, "contender", control)
    finish(contender)
    assert (control.with_suffix(".result")).read_text().splitlines()[0] == "blocked"


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="run-", dir=BASE) as temporary:
        temporary_path = Path(temporary)
        xdg_state = temporary_path / "state"
        xdg_state.mkdir(mode=0o700)
        env = os.environ.copy()
        env.update({"XDG_STATE_HOME": str(xdg_state), "NVIM_APPNAME": "mkchad"})
        hostname = re.sub(r"[^A-Za-z0-9_.-]", "_", socket.gethostname())
        state_root = xdg_state / "mkchad" / "opencode" / hostname
        state_root.mkdir(parents=True, mode=0o700)
        fake = state_root / "fence-opencode"
        fake.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n")
        fake.chmod(0o755)
        target = subprocess.Popen([str(fake), "serve", "--hostname", "127.0.0.1", "--port", "55001"])
        try:
            time.sleep(0.1)
            boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            process = process_record(target.pid, fake, state_root / "server.log")
            pending = {
                "schema": 2,
                "hostname": hostname,
                "generation": "old-generation",
                "boot_id": boot_id,
                "backend": process,
            }
            legacy = {
                "schema": 1,
                "hostname": hostname,
                "pid": target.pid,
                "generation": "old-generation",
                "port": 55001,
                "url": "http://127.0.0.1:55001",
            }
            data_path = temporary_path / "input.json"
            data_path.write_text(json.dumps({"pending": pending, "state": legacy, "process": process, "boot_id": boot_id}))
            data_path.chmod(0o600)

            for action in ("pending_write", "pending_remove", "state_publish", "state_remove", "signal"):
                for path in state_root.glob("*.json"):
                    path.unlink()
                if action == "pending_remove":
                    (state_root / "pending.json").write_text(json.dumps(pending))
                    (state_root / "pending.json").chmod(0o600)
                if action == "state_remove":
                    (state_root / "state.json").write_text(json.dumps(legacy))
                    (state_root / "state.json").chmod(0o600)
                control = temporary_path / action
                holder = run_worker(env, action, control, data_path)
                wait_path(control.with_suffix(".marker"))
                expire_lease(state_root)
                blocked_contender(env, temporary_path / f"{action}-contender")
                if action == "pending_write":
                    assert not (state_root / "pending.json").exists()
                elif action == "pending_remove":
                    assert json.loads((state_root / "pending.json").read_text())["generation"] == "old-generation"
                elif action == "state_publish":
                    assert not (state_root / "state.json").exists()
                elif action == "state_remove":
                    assert json.loads((state_root / "state.json").read_text())["generation"] == "old-generation"
                else:
                    assert target.poll() is None
                control.with_suffix(".resume").write_text("resume")
                if action == "signal":
                    finish(holder, 70)
                    target.wait(timeout=5)
                    break

                wait_path(control.with_suffix(".released"), 70)
                generation = f"new-{action}-generation"
                successor_data = temporary_path / f"{action}-successor.json"
                if action.startswith("pending_"):
                    successor_pending = dict(pending)
                    successor_pending["generation"] = generation
                    successor_data.write_text(json.dumps({"pending": successor_pending}))
                else:
                    successor_state = dict(legacy)
                    successor_state["generation"] = generation
                    successor_data.write_text(json.dumps({"state": successor_state}))
                successor = run_worker(env, "successor", temporary_path / f"{action}-successor", successor_data)
                finish(successor)
                control.with_suffix(".retry").write_text("retry")
                finish(holder)
                result_path = state_root / ("pending.json" if action.startswith("pending_") else "state.json")
                assert json.loads(result_path.read_text())["generation"] == generation

            fence = state_root / "lifecycle.fence"
            assert fence.is_file() and fence.stat().st_mode & 0o777 == 0o600

            owner = run_worker(env, "owner", temporary_path / "dead-owner")
            wait_path(temporary_path / "dead-owner.marker")
            owner.kill()
            reap_killed(owner)
            reclaimer = run_worker(env, "reclaim", temporary_path / "reclaimer")
            wait_path(temporary_path / "reclaimer.marker")
            blocked_contender(env, temporary_path / "reclaim-contender")
            (temporary_path / "reclaimer.resume").write_text("resume")
            finish(reclaimer)

            owner = run_worker(env, "owner", temporary_path / "fd-owner")
            wait_path(temporary_path / "fd-owner.marker")
            fd_loop = run_worker(env, "fd_loop", temporary_path / "fd-loop")
            finish(fd_loop, 10)
            before, after = map(int, (temporary_path / "fd-loop.result").read_text().splitlines())
            assert after <= before, (before, after)
            owner.kill()
            reap_killed(owner)
            successor = run_worker(env, "successor", temporary_path / "death-successor", successor_data)
            finish(successor)
            release_loop = run_worker(env, "release_loop", temporary_path / "release-loop")
            finish(release_loop)
            before, after = map(int, (temporary_path / "release-loop.result").read_text().splitlines())
            assert after <= before, (before, after)
        finally:
            if target.poll() is None:
                target.kill()
                target.wait()


if __name__ == "__main__":
    main()
