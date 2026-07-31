#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def option(name: str) -> str | None:
    try:
        return sys.argv[sys.argv.index(name) + 1]
    except (ValueError, IndexError):
        return None


name = Path(sys.argv[0]).name
if len(sys.argv) > 1 and sys.argv[1].startswith("direct-"):
    phase = sys.argv[1]
elif name == "opencode":
    phase = "version"
elif name == "java":
    phase = "java-validate"
elif "-list" in sys.argv:
    phase = "validate-" + (option("-alias") or "unknown")
elif "-genkeypair" in sys.argv:
    phase = "generate-" + (option("-alias") or "unknown")
elif "-exportcert" in sys.argv:
    phase = "export-ca"
elif "-certreq" in sys.argv:
    phase = "certificate-request"
elif "-gencert" in sys.argv:
    phase = "sign-server"
elif "-importcert" in sys.argv:
    phase = "import-" + (option("-alias") or "unknown")
else:
    phase = "unknown"

target = os.environ.get("MKCHAD_SUBPROCESS_PHASE")
if os.environ.get("MKCHAD_SUBPROCESS_EXIT_PHASE") == phase:
    raise SystemExit(7)
if os.environ.get("MKCHAD_SUBPROCESS_EMPTY_PHASE") == phase:
    raise SystemExit(0)
if target == phase:
    marker = os.environ.get("MKCHAD_SUBPROCESS_PID")
    if marker:
        Path(marker).write_text(str(os.getpid()))
    if phase == "direct-group-leader":
        child = subprocess.Popen([
            sys.executable,
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
        ])
        if marker:
            Path(marker).write_text(str(child.pid))
        while True:
            time.sleep(1)
    elif phase == "direct-stdout":
        sys.stdout.write("x" * (128 * 1024))
        sys.stdout.flush()
    elif phase == "direct-stderr":
        sys.stderr.write("x" * (128 * 1024))
        sys.stderr.flush()
    else:
        if os.environ.get("MKCHAD_SUBPROCESS_RESIST_TERM") == "1":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)

if name == "opencode":
    print("fixture-version")
elif name == "keytool":
    for flag in ("-keystore", "-file", "-outfile"):
        path = option(flag)
        if path:
            Path(path).write_bytes((phase + "\n").encode())
