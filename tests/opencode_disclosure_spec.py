#!/usr/bin/env python3
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "lua" / "configs" / "opencode.lua"
SPEC = ROOT / "tests" / "opencode_auth_disclosure_spec.lua"
CONTENDER = ROOT / "tests" / "opencode_delayed_contender_spec.lua"
BASE = Path("/tmp/opencode-mkchad/disclosure")
PLUGIN = Path(os.environ.get("OPENCODE_NVIM_ROOT", ROOT.parent / "opencode.nvim"))


def repository_snapshot(path: Path) -> bytes:
    status = subprocess.run(["git", "status", "--porcelain=v1", "-z"], cwd=path, check=True, capture_output=True).stdout
    diff = subprocess.run(["git", "diff", "--binary"], cwd=path, check=True, capture_output=True).stdout
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=path,
        check=True,
        capture_output=True,
    ).stdout.split(b"\0")
    contents = []
    for encoded in sorted(item for item in untracked if item):
        file_path = path / os.fsdecode(encoded)
        if file_path.is_file():
            contents.append(encoded + b"\0" + file_path.read_bytes())
    return status + b"\0" + diff + b"\0" + b"\0".join(contents)


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=BASE))
    canary = "mkchad-" + secrets.token_urlsafe(32)
    canary_bytes = canary.encode()
    before = {path: repository_snapshot(path) for path in (ROOT, PLUGIN)}
    success = False
    try:
        for mode in ("tls", "direct"):
            state = root / (mode + "-state")
            config_home = root / (mode + "-config")
            state.mkdir(mode=0o700)
            config_home.mkdir(mode=0o700)
            server_config = config_home / "opencode-server.json"
            env = os.environ.copy()
            for name in ("OPENCODE_PORT", "OPENCODE_SERVER_USERNAME", "OPENCODE_SERVER_PASSWORD"):
                env.pop(name, None)
            env.update({
                "XDG_CONFIG_HOME": str(config_home),
                "XDG_STATE_HOME": str(state),
                "NVIM_APPNAME": "mkchad",
                "MKCHAD_DISCLOSURE_CANARY": canary,
            })
            try:
                result = subprocess.run(
                    ["nvim", "--headless", "-u", "NONE", "-l", str(SPEC), str(CONFIG), str(server_config), mode],
                    env=env,
                    capture_output=True,
                    timeout=120,
                )
            finally:
                cleanup = subprocess.run(
                    ["nvim", "--headless", "-u", "NONE", "-l", str(CONTENDER), str(CONFIG), "cleanup"],
                    env=env,
                    capture_output=True,
                    timeout=60,
                )
                assert cleanup.returncode == 0, cleanup.stderr.decode(errors="replace")
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert canary_bytes not in result.stdout and canary_bytes not in result.stderr, "generated password entered test output"
            for path in state.rglob("*"):
                if path.is_file():
                    assert canary_bytes not in path.read_bytes(), f"generated password persisted in {path}"
        for path, snapshot in before.items():
            assert repository_snapshot(path) == snapshot, f"runtime verification changed repository diff: {path}"
            assert canary_bytes not in repository_snapshot(path), f"generated password entered repository diff: {path}"
        success = True
    finally:
        if success:
            shutil.rmtree(root)
        else:
            print(f"preserved disclosure fixture: {root}")


if __name__ == "__main__":
    main()
