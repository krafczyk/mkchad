local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local root = lifecycle.paths().root
assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))

local function wait_for(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    values, done = { ... }, true
  end)
  assert(vim.wait(timeout or 40000, function()
    return done
  end, 20), "timed out")
  return unpack(values)
end

local function process_argv(pid)
  local fd = assert(vim.uv.fs_open("/proc/" .. pid .. "/cmdline", "r", 0))
  local content = assert(vim.uv.fs_read(fd, 8192, 0))
  vim.uv.fs_close(fd)
  return vim.split(content, "\0", { plain = true, trimempty = true })
end

local function process_dead(pid)
  if not vim.uv.fs_stat("/proc/" .. pid) then
    return true
  end
  local stat = table.concat(vim.fn.readfile("/proc/" .. pid .. "/stat"), "")
  return stat:match("%)%s+Z") ~= nil
end

local fake = vim.fs.joinpath(root, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('fake-2'); raise SystemExit(0)",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen(64)",
  "def handle(client):",
  "  with client:",
  "    while True:",
  "      raw = b''",
  "      while b'\\r\\n\\r\\n' not in raw:",
  "        part = client.recv(4096)",
  "        if not part: return",
  "        raw += part",
  "      head = raw.split(b'\\r\\n\\r\\n', 1)[0]",
  "      if b'authorization: basic' in head.lower():",
  "        client.sendall(b'HTTP/1.1 401 Unauthorized\\r\\nContent-Length: 0\\r\\nConnection: keep-alive\\r\\n\\r\\n'); continue",
  "      body = b'{\\\"healthy\\\":true,\\\"version\\\":\\\"fake-2\\\"}'",
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=handle, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = root .. ":" .. vim.env.PATH

local tui_count, tui_job, tui_command, tui_ca = 0
package.loaded["snacks.terminal"] = {
  get = function(command, opts)
    tui_count = tui_count + 1
    tui_command = command
    tui_ca = opts.env and opts.env.NODE_EXTRA_CA_CERTS
    tui_job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(60)" })
    return {
      job = tui_job,
      valid = function()
        return true
      end,
      close = function(self)
        vim.fn.jobstop(self.job)
      end,
    }, true
  end,
}

assert(lifecycle.read_state() == nil, "configuration load must remain lazy")
package.loaded["opencode.server"] = {}
local inactive_info
local inactive_notify = vim.notify
vim.notify = function(message)
  inactive_info = message
end
lifecycle.show_info()
vim.notify = inactive_notify
assert(inactive_info and inactive_info:find("inactive/untrusted", 1, true), inactive_info)
assert(inactive_info:find("TLS authenticates the OpenCode server, not clients", 1, true), inactive_info)
assert(inactive_info:find("discoverable internal loopback backend", 1, true), inactive_info)
assert(lifecycle.read_state() == nil and not vim.uv.fs_stat(lifecycle.paths().tls), "info changed lifecycle state")
vim.env.OPENCODE_PORT = "invalid"
local invalid_ok, invalid_err = wait_for(vim.g.opencode_opts.server.ensure, 1000)
assert(not invalid_ok and invalid_err:find("must be an integer", 1, true), invalid_err)
vim.env.OPENCODE_PORT = nil

local startup_notifications = {}
local startup_notify = vim.notify
vim.notify = function(message)
  table.insert(startup_notifications, tostring(message))
end
local started, start_err = wait_for(vim.g.opencode_opts.server.ensure)
vim.notify = startup_notify
assert(started, start_err)
local password_warning = false
for _, message in ipairs(startup_notifications) do
  password_warning = password_warning or message:find("both the public proxy and discoverable internal loopback backend", 1, true) ~= nil
end
assert(password_warning, "no-password startup warning was not shown")
local state, state_status = lifecycle.read_state()
assert(state and state_status == "valid" and state.schema == 2)
assert(state.url == ("https://127.0.0.1:%d"):format(state.port))
assert(state.backend.port ~= state.port and state.backend.port >= 49152)
for _, process in ipairs({ state.proxy, state.backend }) do
  assert(type(process.process_executable_dev) == "string" and type(process.process_executable_ino) == "string")
  assert(type(process.executable_dev) == "string" and type(process.executable_ino) == "string")
end
assert(type(state.proxy.source_dev) == "string" and type(state.proxy.source_ino) == "string")
assert(lifecycle.process_is_owned(state))
assert(lifecycle.process_listens_on_port(state.proxy.pid, state.port))
assert(lifecycle.process_listens_on_port(state.backend.pid, state.backend.port))
assert(tui_command[1] == "opencode" and tui_command[2] == "attach" and tui_command[3] == state.url)
assert(tui_command[4] == "--dir" and tui_command[5] == vim.fn.getcwd())
assert(tui_ca == state.ca_path, "attached TUI did not receive the managed CA")

local state_paths = lifecycle.paths()
for _, path in ipairs({ state_paths.state, state_paths.log, state_paths.proxy_log, state_paths.ca, state_paths.ca_store, state_paths.server_store, state_paths.password }) do
  local stat = assert(vim.uv.fs_stat(path), path)
  assert(stat.mode % 512 == 384, path .. " is not mode 0600")
end
assert(assert(vim.uv.fs_stat(state_paths.root)).mode % 512 == 448)
assert(assert(vim.uv.fs_stat(state_paths.tls)).mode % 512 == 448)
local encoded = table.concat(vim.fn.readfile(state_paths.state), "\n")
assert(not encoded:find("OPENCODE_SERVER_PASSWORD", 1, true))
assert(not encoded:find("store.password", 1, true) or encoded:find("--password-file", 1, true), "state may contain only the non-secret password path in proxy argv")

local without_ca = vim.fn.system({ "curl", "--silent", "--show-error", "--max-time", "2", state.url .. "/global/health" })
assert(vim.v.shell_error ~= 0, "curl unexpectedly trusted the private CA")
local with_ca = vim.fn.system({ "curl", "--silent", "--show-error", "--cacert", state.ca_path, "--max-time", "3", state.url .. "/global/health" })
assert(vim.v.shell_error == 0 and with_ca:find("healthy", 1, true), with_ca)

vim.env.OPENCODE_SERVER_PASSWORD = "wrong-for-fixture"
local public_401 = vim.fn.system({
  "curl",
  "--silent",
  "--cacert",
  state.ca_path,
  "--user",
  "opencode:wrong-for-fixture",
  "--write-out",
  "%{http_code}",
  "--output",
  "/dev/null",
  state.url .. "/global/health",
})
assert(vim.v.shell_error == 0 and public_401 == "401", "public authenticated endpoint did not return 401")
local internal_401 = vim.fn.system({
  "curl",
  "--silent",
  "--user",
  "opencode:wrong-for-fixture",
  "--write-out",
  "%{http_code}",
  "--output",
  "/dev/null",
  "http://127.0.0.1:" .. state.backend.port .. "/global/health",
})
assert(vim.v.shell_error == 0 and internal_401 == "401", "direct internal authenticated endpoint did not return 401")
local auth_ok, auth_err = wait_for(vim.g.opencode_opts.server.ensure, 5000)
assert(not auth_ok and auth_err:find("authentication failed", 1, true), auth_err)
assert(lifecycle.read_state().generation == state.generation, "401 replaced the managed pair")
vim.env.OPENCODE_SERVER_PASSWORD = nil

assert(vim.uv.kill(vim.fn.jobpid(tui_job), "sigkill"))
assert(vim.wait(1000, function()
  return vim.fn.jobwait({ tui_job }, 0)[1] ~= -1
end, 20))
assert(wait_for(vim.g.opencode_opts.server.ensure))
assert(tui_count == 2, "dead local TUI was not recreated")

local first_generation = state.generation
local first_ca = state.certificate_identity
local old_backend = state.backend.pid
assert(vim.uv.kill(state.proxy.pid, "sigkill"))
assert(vim.wait(2000, function()
  return process_dead(state.proxy.pid)
end, 20))
local recovered, recover_err = wait_for(vim.g.opencode_opts.server.ensure)
assert(recovered, recover_err)
state = assert(lifecycle.read_state())
assert(state.generation ~= first_generation and state.certificate_identity == first_ca)
assert(process_dead(old_backend), "proxy-only recovery did not stop the old backend")

local proxy_before_backend_death = state.proxy.pid
assert(vim.uv.kill(state.backend.pid, "sigkill"))
assert(vim.wait(2000, function()
  return process_dead(state.backend.pid)
end, 20))
assert(wait_for(vim.g.opencode_opts.server.ensure))
state = assert(lifecycle.read_state())
assert(state.proxy.pid ~= proxy_before_backend_death, "backend-only recovery did not replace the proxy first")
assert(state.certificate_identity == first_ca, "ordinary recovery rotated the public certificate")

local lock_ok, lock_err = wait_for(lifecycle.acquire_lock, 3000)
assert(lock_ok, lock_err)
local stopped, stop_err = wait_for(function(done)
  lifecycle.stop_pair(state, vim.uv.hrtime() + 8000 * 1000000, done)
end, 10000)
assert(stopped, stop_err)
vim.uv.fs_unlink(state_paths.state)
lifecycle.release_lock()

-- Explicit public conflicts fail without launching a pair or selecting fallback.
local conflict = assert(vim.uv.new_tcp())
assert(conflict:bind("127.0.0.1", 0) == 0 and conflict:listen(1, function() end) == 0)
vim.env.OPENCODE_PORT = tostring(conflict:getsockname().port)
local conflict_ok, conflict_err = wait_for(vim.g.opencode_opts.server.ensure, 5000)
assert(not conflict_ok and conflict_err:find("occupied", 1, true), conflict_err)
assert(lifecycle.read_state() == nil)
vim.env.OPENCODE_PORT = nil
conflict:close()

local future = vim.json.encode({ schema = 3, sentinel = "preserve-future-state" })
vim.fn.writefile({ future }, state_paths.state)
local future_ok, future_err = wait_for(vim.g.opencode_opts.server.ensure, 5000)
assert(not future_ok and future_err:find("unsupported future", 1, true), future_err)
assert(table.concat(vim.fn.readfile(state_paths.state), "\n") == future, "future state was overwritten")

vim.fn.writefile({ "{" }, state_paths.state)
package.loaded["opencode.server"] = package.loaded["opencode.server"] or {}
local malformed_info
local original_notify = vim.notify
vim.notify = function(message)
  malformed_info = message
end
lifecycle.show_info()
vim.notify = original_notify
assert(malformed_info and malformed_info:find("State status: malformed", 1, true), malformed_info)
local malformed_recovered, malformed_err = wait_for(vim.g.opencode_opts.server.ensure)
assert(malformed_recovered, malformed_err)
local malformed_state = assert(lifecycle.read_state())
lock_ok, lock_err = wait_for(lifecycle.acquire_lock, 3000)
assert(lock_ok, lock_err)
stopped, stop_err = wait_for(function(done)
  lifecycle.stop_pair(malformed_state, vim.uv.hrtime() + 8000 * 1000000, done)
end, 10000)
assert(stopped, stop_err)
vim.uv.fs_unlink(state_paths.state)
lifecycle.release_lock()

-- Schema 1 is diagnosed without a probe and migrated only after exact process verification.
local legacy_port = assert(lifecycle.select_port(nil))
local legacy_job = vim.fn.jobstart({ fake, "serve", "--hostname", "127.0.0.1", "--port", tostring(legacy_port) })
local legacy_pid = vim.fn.jobpid(legacy_job)
assert(vim.wait(3000, function()
  return lifecycle.process_listens_on_port(legacy_pid, legacy_port)
end, 20))
local legacy = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = legacy_pid,
  generation = "legacy-generation",
  port = legacy_port,
  url = "http://127.0.0.1:" .. legacy_port,
  process_executable = vim.uv.fs_readlink("/proc/" .. legacy_pid .. "/exe"),
  argv = process_argv(legacy_pid),
}
assert(lifecycle.write_state(legacy))
local observed
original_notify = vim.notify
package.loaded["opencode.server"] = package.loaded["opencode.server"] or {}
vim.notify = function(message)
  observed = message
end
lifecycle.show_info()
vim.notify = original_notify
assert(observed and observed:find("legacy", 1, true) and observed:find("never probed", 1, true), observed)
local migrated, migrate_err = wait_for(vim.g.opencode_opts.server.ensure)
assert(migrated, migrate_err)
state = assert(lifecycle.read_state())
assert(state.schema == 2 and state.generation ~= legacy.generation)
assert(vim.wait(2000, function()
  return process_dead(legacy_pid)
end, 20), "verified legacy process survived migration")

lock_ok, lock_err = wait_for(lifecycle.acquire_lock, 3000)
assert(lock_ok, lock_err)
stopped, stop_err = wait_for(function(done)
  lifecycle.stop_pair(state, vim.uv.hrtime() + 8000 * 1000000, done)
end, 10000)
assert(stopped, stop_err)
vim.uv.fs_unlink(state_paths.state)
lifecycle.release_lock()

local stop_port = assert(lifecycle.select_port(nil))
local stop_job = vim.fn.jobstart({ fake, "serve", "--hostname", "127.0.0.1", "--port", tostring(stop_port) })
local stop_pid = vim.fn.jobpid(stop_job)
assert(vim.wait(3000, function()
  return lifecycle.process_listens_on_port(stop_pid, stop_port)
end, 20))
local stop_state = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = stop_pid,
  generation = "explicit-legacy-stop",
  port = stop_port,
  url = "http://127.0.0.1:" .. stop_port,
  process_executable = vim.uv.fs_readlink("/proc/" .. stop_pid .. "/exe"),
  argv = process_argv(stop_pid),
}
assert(lifecycle.write_state(stop_state))
lock_ok, lock_err = wait_for(lifecycle.acquire_lock, 3000)
assert(lock_ok, lock_err)
local legacy_stopped, legacy_stop_err = wait_for(function(done)
  lifecycle.stop_legacy(stop_state, vim.uv.hrtime() + 8000 * 1000000, done)
end, 10000)
assert(legacy_stopped, legacy_stop_err)
vim.uv.fs_unlink(state_paths.state)
lifecycle.release_lock()
assert(process_dead(stop_pid), "explicit verified legacy stop left its process live")
if tui_job and vim.fn.jobwait({ tui_job }, 0)[1] == -1 then
  vim.fn.jobstop(tui_job)
end
vim.cmd("qa!")
