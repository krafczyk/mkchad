#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "opencode_pidfd_signal.py"


def record(pid: int) -> dict:
    stat_text = Path(f"/proc/{pid}/stat").read_text()
    runtime = os.stat(f"/proc/{pid}/exe")
    executable = os.readlink(f"/proc/{pid}/exe").removesuffix(" (deleted)")
    argv = [os.fsdecode(value) for value in Path(f"/proc/{pid}/cmdline").read_bytes()[:-1].split(b"\0")]
    return {
        "pid": pid,
        "port": 55001,
        "argv": argv,
        "process_executable": os.readlink(f"/proc/{pid}/exe"),
        "process_executable_dev": str(runtime.st_dev),
        "process_executable_ino": str(runtime.st_ino),
        "executable": executable,
        "executable_dev": str(runtime.st_dev),
        "executable_ino": str(runtime.st_ino),
        "start_time": stat_text[stat_text.rindex(")") + 2 :].split()[19],
        "local_version": "pidfd-test",
        "log": "/tmp/opencode/pidfd-test.log",
    }


def invoke(process: dict) -> subprocess.CompletedProcess:
    request = {
        "schema": 1,
        "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "signal": "SIGTERM",
        "process": process,
    }
    return subprocess.run(["python3", str(HELPER)], input=json.dumps(request), text=True, capture_output=True, timeout=3)


def main() -> None:
    first = subprocess.Popen(["sleep", "60"])
    time.sleep(0.05)
    surrogate = subprocess.Popen(["sleep", "60"])
    try:
        time.sleep(0.05)
        mismatched = record(first.pid)
        mismatched["pid"] = surrogate.pid
        refused = invoke(mismatched)
        assert refused.returncode != 0
        assert surrogate.poll() is None, "identity mismatch signaled the surrogate PID"

        valid = invoke(record(surrogate.pid))
        assert valid.returncode == 0, valid.stderr
        surrogate.wait(timeout=3)
        assert surrogate.returncode == -signal.SIGTERM
    finally:
        for process in (first, surrogate):
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
