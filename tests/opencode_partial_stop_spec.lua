local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()
assert(vim.fn.mkdir(paths.root, "p", 448) ~= 0 or vim.uv.fs_stat(paths.root))

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 8000, function()
    return done
  end, 20), "partial-stop operation timed out")
  return unpack(values)
end

local function process_dead(pid)
  if not vim.uv.fs_stat("/proc/" .. pid) then
    return true
  end
  local stat = table.concat(vim.fn.readfile("/proc/" .. pid .. "/stat"), "")
  return stat:match("%)%s+Z") ~= nil
end

local fake = vim.fs.joinpath(paths.root, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import signal, sys, time",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('partial-stop'); raise SystemExit(0)",
  "signal.signal(signal.SIGTERM, signal.SIG_IGN)",
  "time.sleep(60)",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
local fake_identity = assert(lifecycle.file_identity(fake))
local fake_proxy = vim.fs.joinpath(paths.root, "java")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import time",
  "time.sleep(60)",
}, fake_proxy)
assert(vim.uv.fs_chmod(fake_proxy, 493))
local fake_proxy_identity = assert(lifecycle.file_identity(fake_proxy))
local proxy_source_identity = assert(lifecycle.file_identity(paths.proxy_source))

local controlled_helper = vim.fs.joinpath(paths.root, "controlled-pidfd-helper.py")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import json, os, sys, time",
  "request = json.load(sys.stdin)",
  "mode = os.environ.get('MKCHAD_PARTIAL_HELPER_MODE')",
  "if mode == 'hang': time.sleep(10); raise SystemExit(0)",
  "if mode == 'nonzero' or (mode == 'reject-kill' and request.get('signal') == 'SIGKILL'):",
  "  sys.stderr.write('controlled helper refusal')",
  "  raise SystemExit(7)",
  "raise SystemExit(0)",
}, controlled_helper)
assert(vim.uv.fs_chmod(controlled_helper, 448))
local real_helper = paths.pidfd_helper
local sequence = 0

local function start_state()
  sequence = sequence + 1
  local port = 56000 + sequence
  local job = vim.fn.jobstart({ fake, "serve", "--hostname", "127.0.0.1", "--port", tostring(port) })
  local pid = vim.fn.jobpid(job)
  assert(pid > 0)
  assert(vim.wait(2000, function()
    local executable = vim.uv.fs_readlink("/proc/" .. pid .. "/exe")
    return lifecycle.proc_start_time(pid) ~= nil and executable and not executable:match("/env$")
  end, 20), "partial-stop backend did not finish interpreter exec")
  local backend = assert(lifecycle.capture_process(pid, {
    port = port,
    executable = fake,
    executable_dev = fake_identity.dev,
    executable_ino = fake_identity.ino,
    local_version = "partial-stop",
    log = paths.log,
  }))
  local state = {
    schema = 3,
    transport = "tls-proxy",
    hostname = (vim.uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_"),
    generation = "partial-stop-" .. sequence,
    host = "127.0.0.1",
    port = port + 1000,
    url = "https://127.0.0.1:" .. (port + 1000),
    port_source = "fallback",
    started_at = "2026-07-15T12:00:00Z",
    cwd = "/tmp/opencode",
    boot_id = assert(lifecycle.current_boot_id()),
    ca_path = paths.ca,
    certificate_identity = string.rep("a", 64),
    backend = backend,
  }
  local proxy_job = vim.fn.jobstart({
    fake_proxy,
    "--source",
    "21",
    paths.proxy_source,
    "--listen-port",
    tostring(state.port),
    "--backend-port",
    tostring(port),
    "--backend-pid",
    tostring(backend.pid),
    "--backend-start",
    backend.start_time,
    "--boot-id",
    state.boot_id,
    "--keystore",
    paths.server_store,
    "--password-file",
    paths.password,
    "--max-connections",
    "128",
  })
  local proxy_pid = vim.fn.jobpid(proxy_job)
  assert(proxy_pid > 0)
  assert(vim.wait(2000, function()
    local executable = vim.uv.fs_readlink("/proc/" .. proxy_pid .. "/exe")
    return lifecycle.proc_start_time(proxy_pid) ~= nil and executable and not executable:match("/env$")
  end, 20), "partial-stop proxy did not finish interpreter exec")
  state.proxy = assert(lifecycle.capture_process(proxy_pid, {
    port = state.port,
    executable = fake_proxy,
    executable_dev = fake_proxy_identity.dev,
    executable_ino = fake_proxy_identity.ino,
    source = paths.proxy_source,
    source_dev = proxy_source_identity.dev,
    source_ino = proxy_source_identity.ino,
    log = paths.proxy_log,
  }))
  state.proxy.executable = state.proxy.process_executable
  state.proxy.executable_dev = state.proxy.process_executable_dev
  state.proxy.executable_ino = state.proxy.process_executable_ino
  state.proxy.argv = {
    state.proxy.executable,
    "--source",
    "21",
    paths.proxy_source,
    "--listen-port",
    tostring(state.port),
    "--backend-port",
    tostring(port),
    "--backend-pid",
    tostring(backend.pid),
    "--backend-start",
    backend.start_time,
    "--boot-id",
    state.boot_id,
    "--keystore",
    paths.server_store,
    "--password-file",
    paths.password,
    "--max-connections",
    "128",
  }
  assert(vim.uv.kill(proxy_pid, "sigkill"))
  assert(vim.wait(2000, function()
    return process_dead(proxy_pid)
  end, 20), "partial-stop proxy fixture did not die")
  vim.fn.jobwait({ proxy_job }, 1000)
  local locked, lock_err = await(lifecycle.acquire_lock, 3000)
  assert(locked, lock_err)
  assert(lifecycle.write_state(state))
  lifecycle.release_lock()
  return job, state
end

local function cleanup(job, state)
  vim.g.mkchad_opencode_test_pidfd_helper = real_helper
  vim.env.MKCHAD_PARTIAL_HELPER_MODE = nil
  local locked, lock_err = await(lifecycle.acquire_lock, 3000)
  assert(locked, lock_err)
  local stopped, stop_err = await(function(done)
    lifecycle.stop_pair(state, vim.uv.hrtime() + 1000 * 1000000, done)
  end, 5000)
  assert(stopped, stop_err)
  assert(lifecycle.remove_matching_state_while_locked(state.generation, "partial-stop test cleanup"))
  lifecycle.release_lock()
  assert(vim.wait(2000, function()
    return process_dead(state.backend.pid)
  end, 20), "partial-stop fixture survived cleanup")
  vim.fn.jobwait({ job }, 1000)
  vim.g.mkchad_opencode_test_pidfd_helper = nil
end

local function expect_failure(label, helper, mode, expected)
  local job, state = start_state()
  local before = table.concat(vim.fn.readfile(paths.state), "\n")
  vim.g.mkchad_opencode_test_pidfd_helper = helper
  vim.g.mkchad_opencode_test_stop_timeout_ms = 1000
  vim.env.MKCHAD_PARTIAL_HELPER_MODE = mode
  local notice
  local original_notify = vim.notify
  local started_at = vim.uv.hrtime()
  vim.notify = function(message)
    notice = tostring(message)
  end
  lifecycle.stop_shared_server()
  assert(vim.wait(7000, function()
    return notice ~= nil
  end, 20), label .. " stop timed out")
  assert((vim.uv.hrtime() - started_at) / 1000000 < 2000, label .. " exceeded the stop deadline bound")
  vim.notify = original_notify
  assert(notice:find(expected, 1, true), label .. ": " .. notice)
  assert(table.concat(vim.fn.readfile(paths.state), "\n") == before, label .. " changed state")
  assert(not process_dead(state.backend.pid), label .. " unexpectedly stopped the backend")
  cleanup(job, state)
end

expect_failure("missing helper", vim.fs.joinpath(paths.root, "missing-helper.py"), nil, "unavailable")
expect_failure("nonzero helper", controlled_helper, "nonzero", "controlled helper refusal")
expect_failure("hanging helper", controlled_helper, "hang", "timed out")
expect_failure("rejected SIGKILL", controlled_helper, "reject-kill", "controlled helper refusal")
expect_failure("unconfirmed death", controlled_helper, "noop", "did not exit after SIGKILL")

do
  local job, state = start_state()
  local malformed = vim.deepcopy(state)
  malformed.backend.executable_ino = "1"
  vim.fn.writefile({ vim.json.encode(malformed) }, paths.state)
  local before = table.concat(vim.fn.readfile(paths.state), "\n")
  local notice
  local original_notify = vim.notify
  vim.notify = function(message)
    notice = tostring(message)
  end
  lifecycle.stop_shared_server()
  assert(vim.wait(3000, function()
    return notice ~= nil
  end, 20), "identity mismatch stop timed out")
  vim.notify = original_notify
  assert(notice:find("identity", 1, true), notice)
  assert(table.concat(vim.fn.readfile(paths.state), "\n") == before)
  assert(not process_dead(state.backend.pid), "identity mismatch signaled the backend")
  cleanup(job, state)
end

do
  local job, state = start_state()
  vim.g.mkchad_opencode_test_pidfd_helper = real_helper
  vim.g.mkchad_opencode_test_stop_timeout_ms = 1000
  local notice
  local original_notify = vim.notify
  vim.notify = function(message)
    notice = tostring(message)
  end
  lifecycle.stop_shared_server()
  assert(vim.wait(5000, function()
    return notice ~= nil
  end, 20), "TERM-resistant stop timed out")
  vim.notify = original_notify
  assert(notice:find("Stopped shared OpenCode proxy and backend", 1, true), notice)
  assert(process_dead(state.backend.pid), "SIGKILL escalation did not stop the TERM-resistant backend")
  assert(lifecycle.read_state() == nil)
  vim.fn.jobwait({ job }, 1000)
end

vim.g.mkchad_opencode_test_pidfd_helper = nil
vim.g.mkchad_opencode_test_stop_timeout_ms = nil
vim.env.MKCHAD_PARTIAL_HELPER_MODE = nil
vim.cmd("qa!")
