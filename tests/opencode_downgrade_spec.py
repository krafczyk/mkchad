#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "lua" / "configs" / "opencode.lua"
CONTENDER = ROOT / "tests" / "opencode_delayed_contender_spec.lua"
WORKER = ROOT / "tests" / "opencode_downgrade_worker.lua"
BASE = Path("/tmp/opencode-mkchad/downgrade")
# Reviewed pre-broker lifecycle revision. It must fail closed on schema-4
# authority without altering records or signaling their recorded processes.
BASELINE = "938c325"


def run_nvim(env: dict[str, str], script: Path, *args: str, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["nvim", "--headless", "-u", "NONE", "-l", str(script), *map(str, args)],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def baseline_config(root: Path) -> Path:
    source = subprocess.run(
        ["git", "show", f"{BASELINE}:lua/configs/opencode.lua"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout
    path = root / "baseline" / "lua" / "configs" / "opencode.lua"
    path.parent.mkdir(parents=True, mode=0o700)
    path.write_bytes(source)
    helper_source = subprocess.run(
        ["git", "show", f"{BASELINE}:scripts/opencode_pidfd_signal.py"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout
    helper = root / "baseline" / "scripts" / "opencode_pidfd_signal.py"
    helper.parent.mkdir(parents=True, mode=0o700)
    helper.write_bytes(helper_source)
    return path


def complete_state_case(root: Path, baseline: Path) -> None:
    state_root = root / "complete-state"
    results = root / "complete-results"
    state_root.mkdir(mode=0o700)
    results.mkdir(mode=0o700)
    server_config = root / "direct-server.json"
    server_config.write_text(json.dumps({"tls_proxy": True}))
    server_config.chmod(0o600)
    env = os.environ.copy()
    for name in ("OPENCODE_PORT", "OPENCODE_SERVER_USERNAME", "OPENCODE_SERVER_PASSWORD"):
        env.pop(name, None)
    env.update({
        "XDG_STATE_HOME": str(state_root),
        "NVIM_APPNAME": "mkchad",
        "MKCHAD_OPENCODE_RESULT": str(results / "result"),
        "MKCHAD_OPENCODE_SERVER_CONFIG": str(server_config),
    })

    backend_pid = None
    try:
        setup = run_nvim(env, CONTENDER, CONFIG, "setup")
        assert setup.returncode == 0, setup.stderr
        worker = run_nvim(env, CONTENDER, CONFIG, "worker")
        assert worker.returncode == 0, worker.stderr
        state_path = next(state_root.glob("mkchad/opencode/*/state.json"))
        before = state_path.read_bytes()
        state = json.loads(before)
        assert state["schema"] == 4 and state["transport"] == "tls-proxy"
        backend_pid = state["backend"]["pid"]
        proxy_pid = state["proxy"]["pid"]
        assert Path(f"/proc/{backend_pid}").exists()
        assert Path(f"/proc/{proxy_pid}").exists()
        env["PATH"] = str(Path(state["backend"]["executable"]).parent) + os.pathsep + env["PATH"]
        checked = run_nvim(env, WORKER, baseline, "complete")
        assert checked.returncode == 0, checked.stderr
        assert state_path.read_bytes() == before, "baseline mutated schema-4 complete state"
        assert Path(f"/proc/{backend_pid}").exists(), "baseline signaled the schema-4 backend"
        assert Path(f"/proc/{proxy_pid}").exists(), "baseline signaled the schema-4 broker"
        assert len(list(state_root.glob("mkchad/opencode/*/state.json"))) == 1
    finally:
        cleanup = run_nvim(env, CONTENDER, CONFIG, "cleanup")
        assert cleanup.returncode == 0, cleanup.stderr
    if backend_pid is not None:
        assert not Path(f"/proc/{backend_pid}").exists()


def pending_case(root: Path, baseline: Path) -> None:
    state_root = root / "pending-state"
    results = root / "pending-results"
    state_root.mkdir(mode=0o700)
    results.mkdir(mode=0o700)
    env = os.environ.copy()
    for name in ("OPENCODE_PORT", "OPENCODE_SERVER_USERNAME", "OPENCODE_SERVER_PASSWORD"):
        env.pop(name, None)
    env.update({"XDG_STATE_HOME": str(state_root), "NVIM_APPNAME": "mkchad"})
    env["MKCHAD_OPENCODE_RESULT"] = str(results / "result")
    state_path = None
    state_before = None
    try:
        setup = run_nvim(env, CONTENDER, CONFIG, "setup")
        assert setup.returncode == 0, setup.stderr
        worker = run_nvim(env, CONTENDER, CONFIG, "worker")
        assert worker.returncode == 0, worker.stderr
        state_path = next(state_root.glob("mkchad/opencode/*/state.json"))
        state_before = state_path.read_bytes()
        state = json.loads(state_before)
        assert state["schema"] == 4 and state["transport"] == "tls-proxy"
        pending_root = state_path.parent
        pending_path = pending_root / "pending.json"
        launch_path = pending_root / "launch.json"
        pending = {
            "schema": 4,
            "transport": "tls-proxy",
            "phase": "running",
            "hostname": state["hostname"],
            "generation": state["generation"],
            "boot_id": state["boot_id"],
            "proxy": state["proxy"],
            "backend": state["backend"],
            "broker": state["broker"],
        }
        launch = {
            "schema": 2,
            "transport": "tls-proxy",
            "hostname": state["hostname"],
            "generation": state["generation"],
            "boot_id": state["boot_id"],
            "proxy": {
                key: state["proxy"][key]
                for key in ("port", "executable", "executable_dev", "executable_ino", "source", "source_dev", "source_ino", "log", "argv", "pid")
            },
            "public": {"role": "public", "port": state["port"]},
            "control": {"protocol": 1, "path": state["broker"]["control_path"]},
            "backend": {
                "role": "backend",
                "executable": state["backend"]["executable"],
                "executable_dev": state["backend"]["executable_dev"],
                "executable_ino": state["backend"]["executable_ino"],
                "version": state["backend"]["local_version"],
                "port": state["backend"]["port"],
                "log": state["backend"]["log"],
            },
        }
        launch["proxy"]["role"] = "proxy"
        state_path.unlink()
        pending_path.write_text(json.dumps(pending))
        pending_path.chmod(0o600)
        launch_path.write_text(json.dumps(launch))
        launch_path.chmod(0o600)
        before = pending_path.read_bytes()
        launch_before = launch_path.read_bytes()
        checked = run_nvim(env, WORKER, baseline, "pending")
        assert checked.returncode == 0, checked.stderr
        assert pending_path.read_bytes() == before, "baseline mutated schema-4 pending metadata"
        assert launch_path.read_bytes() == launch_before, "baseline mutated schema-4 broker launch metadata"
        for process in (state["proxy"], state["backend"]):
            assert Path(f"/proc/{process['pid']}").exists(), "baseline signaled a schema-4 pending role"
    finally:
        if state_path and state_before:
            state_path.write_bytes(state_before)
            for path in (state_path.parent / "pending.json", state_path.parent / "launch.json"):
                path.unlink(missing_ok=True)
            cleanup = run_nvim(env, CONTENDER, CONFIG, "cleanup")
            assert cleanup.returncode == 0, cleanup.stderr


def rollback_case(root: Path, baseline: Path) -> None:
    state_root = root / "rollback-state"
    results = root / "rollback-results"
    config_home = root / "rollback-config"
    state_root.mkdir(mode=0o700)
    results.mkdir(mode=0o700)
    config_home.mkdir(mode=0o700)
    server_config = config_home / "opencode-server.json"
    server_config.write_text(json.dumps({"tls_proxy": True}))
    server_config.chmod(0o600)
    env = os.environ.copy()
    for name in ("OPENCODE_PORT", "OPENCODE_SERVER_USERNAME", "OPENCODE_SERVER_PASSWORD"):
        env.pop(name, None)
    env.update({
        "XDG_CONFIG_HOME": str(config_home),
        "XDG_STATE_HOME": str(state_root),
        "NVIM_APPNAME": "mkchad",
        "MKCHAD_OPENCODE_RESULT": str(results / "current"),
        "MKCHAD_OPENCODE_SERVER_CONFIG": str(server_config),
    })

    try:
        setup = run_nvim(env, CONTENDER, CONFIG, "setup")
        assert setup.returncode == 0, setup.stderr
        current = run_nvim(env, CONTENDER, CONFIG, "worker")
        assert current.returncode == 0, current.stderr
        state_path = next(state_root.glob("mkchad/opencode/*/state.json"))
        current_state = json.loads(state_path.read_bytes())
        assert current_state["schema"] == 4 and current_state["transport"] == "tls-proxy"
        current_pids = [current_state["proxy"]["pid"], current_state["backend"]["pid"]]
        ca_before = Path(current_state["ca_path"]).read_bytes()

        cleanup = run_nvim(env, CONTENDER, CONFIG, "cleanup")
        assert cleanup.returncode == 0, cleanup.stderr
        for pid in current_pids:
            assert not Path(f"/proc/{pid}").exists(), "schema-4 role survived rollback stop"
        lifecycle_root = state_path.parent
        for name in ("state.json", "pending.json", "launch.json"):
            assert not (lifecycle_root / name).exists(), f"rollback retained {name}"
        server_config.write_text("{}")
        server_config.chmod(0o600)
        assert "tls_proxy" not in server_config.read_text()

        baseline_proxy = config_home / "mkchad" / "java" / "MkChadTlsProxy.java"
        baseline_proxy.parent.mkdir(parents=True, mode=0o700)
        shutil.copyfile(ROOT / "java" / "MkChadTlsProxy.java", baseline_proxy)
        fake_root = Path(current_state["backend"]["executable"]).parent
        env["PATH"] = str(fake_root) + os.pathsep + env["PATH"]
        result_path = results / "baseline"
        rolled_back = run_nvim(env, WORKER, baseline, "rollback-start", result_path, timeout=90)
        assert rolled_back.returncode == 0, rolled_back.stderr
        assert len(result_path.read_text().splitlines()) == 3
        assert not state_path.exists(), "baseline rollback stop retained state"
        assert not (lifecycle_root / "pending.json").exists()
        assert Path(current_state["ca_path"]).read_bytes() == ca_before, "rollback changed the retained CA"
    finally:
        baseline_cleanup = run_nvim(env, CONTENDER, baseline, "cleanup")
        assert baseline_cleanup.returncode == 0, baseline_cleanup.stderr
        feature_cleanup = run_nvim(env, CONTENDER, CONFIG, "cleanup")
        assert feature_cleanup.returncode == 0, feature_cleanup.stderr


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=BASE))
    success = False
    try:
        baseline = baseline_config(root)
        complete_state_case(root, baseline)
        pending_case(root, baseline)
        rollback_case(root, baseline)
        success = True
    finally:
        if success:
            shutil.rmtree(root)
        else:
            print(f"preserved downgrade fixture: {root}")


if __name__ == "__main__":
    main()
