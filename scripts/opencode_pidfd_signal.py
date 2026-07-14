#!/usr/bin/env python3
"""Signal one exactly identified Linux process through a pidfd."""

import json
import os
from pathlib import Path
import signal
import sys
import time


MAX_REQUEST = 1024 * 1024


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_request() -> dict:
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    if not raw or len(raw) > MAX_REQUEST:
        fail("invalid pidfd signal request size")
    try:
        request = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("invalid pidfd signal request")
    if not isinstance(request, dict) or request.get("schema") != 1:
        fail("unsupported pidfd signal request")
    return request


def proc_start_time(pid: int) -> str:
    try:
        value = Path(f"/proc/{pid}/stat").read_text()
        fields = value[value.rindex(")") + 2 :].split()
        return fields[19]
    except (OSError, ValueError, IndexError):
        fail("unable to validate process start identity")


def proc_argv(pid: int) -> list[str]:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        fail("unable to validate process argv")
    if not raw or not raw.endswith(b"\0"):
        fail("unable to validate process argv")
    return [os.fsdecode(value) for value in raw[:-1].split(b"\0")]


def identity(path: str) -> tuple[str, str]:
    try:
        stat = os.stat(path)
    except OSError:
        fail("unable to validate executable identity")
    return str(stat.st_dev), str(stat.st_ino)


def validate_after_pidfd_open(request: dict) -> tuple[int, int]:
    process = request.get("process")
    pid = process.get("pid") if isinstance(process, dict) else None
    if not isinstance(pid, int) or isinstance(pid, bool) or pid < 1 or pid > 2147483647:
        fail("invalid managed PID")
    expected_signal = request.get("signal")
    signals = {"SIGTERM": signal.SIGTERM, "SIGKILL": signal.SIGKILL}
    if expected_signal not in signals:
        fail("invalid managed signal")

    try:
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        fail("unable to validate host boot identity")
    if boot_id != request.get("boot_id"):
        fail("host boot identity changed")

    expected_argv = process.get("argv")
    runtime = (process.get("process_executable_dev"), process.get("process_executable_ino"))
    if (
        not isinstance(expected_argv, list)
        or not expected_argv
        or any(not isinstance(value, str) or not value for value in expected_argv)
        or any(not isinstance(value, str) or not value.isdecimal() for value in runtime)
        or proc_start_time(pid) != process.get("start_time")
        or proc_argv(pid) != expected_argv
        or identity(f"/proc/{pid}/exe") != runtime
    ):
        fail("managed process identity changed")

    launch = (process.get("executable_dev"), process.get("executable_ino"))
    if launch != runtime:
        executable = process.get("executable")
        if not isinstance(executable, str) or not executable.startswith("/") or identity(executable) != launch:
            fail("managed launch executable identity changed")

    source = process.get("source")
    if source is not None:
        source_identity = (process.get("source_dev"), process.get("source_ino"))
        if not isinstance(source, str) or not source.startswith("/") or identity(source) != source_identity:
            fail("managed source identity changed")
    return pid, signals[expected_signal]


def test_pause(request: dict) -> None:
    pause = request.get("test_pause")
    if os.environ.get("MKCHAD_OPENCODE_PIDFD_TEST") != "1" or not isinstance(pause, dict):
        return
    marker, resume = pause.get("marker"), pause.get("resume")
    if not isinstance(marker, str) or not isinstance(resume, str) or not marker.startswith("/") or not resume.startswith("/"):
        fail("invalid pidfd test pause")
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    deadline = time.monotonic() + 60
    while not os.path.exists(resume):
        if time.monotonic() >= deadline:
            fail("pidfd test pause timed out")
        time.sleep(0.01)


def main() -> None:
    request = read_request()
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        fail("Linux pidfd signaling is unavailable")
    process = request.get("process")
    pid = process.get("pid") if isinstance(process, dict) else None
    if not isinstance(pid, int) or isinstance(pid, bool):
        fail("invalid managed PID")
    try:
        pidfd = os.pidfd_open(pid, 0)
    except OSError:
        fail("unable to open managed process pidfd")
    try:
        _, signum = validate_after_pidfd_open(request)
        test_pause(request)
        signal.pidfd_send_signal(pidfd, signum, None, 0)
    except OSError:
        fail("pidfd signal dispatch failed")
    finally:
        os.close(pidfd)


if __name__ == "__main__":
    main()
