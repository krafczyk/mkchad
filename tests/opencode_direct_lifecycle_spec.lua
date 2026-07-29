local config = assert(arg[1], "pass the MkChad OpenCode config path")
local server_config = assert(arg[2], "pass an isolated server config path")

vim.env.OPENCODE_PORT = nil
vim.env.OPENCODE_SERVER_USERNAME = nil
vim.env.OPENCODE_SERVER_PASSWORD = nil

assert(vim.fn.mkdir(vim.fs.dirname(server_config), "p", 448) ~= 0 or vim.uv.fs_stat(vim.fs.dirname(server_config)))
vim.fn.writefile({ vim.json.encode { tls_proxy = false } }, server_config)
assert(vim.uv.fs_chmod(server_config, 384))
vim.g.mkchad_opencode_test_api = true
vim.g.mkchad_opencode_test_server_config = server_config
dofile(config)

local lifecycle = vim.g.mkchad_opencode_test_api
local root = lifecycle.paths().root
assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
assert(lifecycle.requested_transport() == "loopback-http")

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(
    vim.wait(timeout or 15000, function()
      return done
    end, 20),
    "operation timed out"
  )
  return unpack(values)
end

local function process_dead(pid)
  if not vim.uv.fs_stat("/proc/" .. pid) then
    return true
  end
  local stat = table.concat(vim.fn.readfile("/proc/" .. pid .. "/stat"), "")
  return stat:match "%)%s+Z" ~= nil
end

local fake = vim.fs.joinpath(root, "opencode")
local spawn_log = vim.fs.joinpath(root, "backend-spawns.log")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import base64, os, socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('fake-direct-1'); raise SystemExit(0)",
  "with open(" .. vim.json.encode(spawn_log) .. ", 'a') as out: out.write(str(os.getpid()) + '\\n')",
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
  "      password = os.environ.get('OPENCODE_SERVER_PASSWORD')",
  "      username = os.environ.get('OPENCODE_SERVER_USERNAME', 'opencode')",
  "      expected = b'Authorization: Basic ' + base64.b64encode((username + ':' + password).encode()) if password else None",
  "      if expected and expected not in raw.split(b'\\r\\n\\r\\n', 1)[0]:",
  "        client.sendall(b'HTTP/1.1 401 Unauthorized\\r\\nContent-Length: 0\\r\\nConnection: keep-alive\\r\\n\\r\\n'); continue",
  '      body = b\'{\\"healthy\\":true,\\"version\\":\\"fake-direct-1\\"}\'',
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=handle, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = root .. ":" .. vim.env.PATH

local tui_command, tui_ca
package.loaded["snacks.terminal"] = {
  get = function(command, opts)
    tui_command = command
    tui_ca = opts.env and opts.env.NODE_EXTRA_CA_CERTS
    local job = vim.fn.jobstart { "python3", "-c", "import time; time.sleep(60)" }
    return {
      job = job,
      valid = function()
        return true
      end,
      close = function(self)
        vim.fn.jobstop(self.job)
      end,
    },
      true
  end,
}
package.loaded["opencode.server"] = {}

assert(lifecycle.read_state() == nil)
local started, start_err = await(vim.g.opencode_opts.server.ensure)
assert(started, start_err)
local state, state_status = lifecycle.read_state()
assert(state_status == "valid" and state.schema == 3 and state.transport == "loopback-http")
assert(state.url == ("http://127.0.0.1:%d"):format(state.port))
assert(state.proxy == nil and state.ca_path == nil and state.certificate_identity == nil)
assert(state.backend.port == state.port)
assert(lifecycle.process_is_owned(state))
assert(lifecycle.process_listens_on_port(state.backend.pid, state.port))
assert(tui_command[1] == "opencode" and tui_command[2] == "attach" and tui_command[3] == state.url)
assert(tui_ca == nil, "direct TUI received a TLS CA setting")
assert(vim.g.opencode_opts.server.ca_cert() == nil, "direct plugin state exposed a CA")
assert(not vim.uv.fs_stat(lifecycle.paths().tls), "direct startup created TLS material")

local response = vim.fn.system { "curl", "--silent", "--show-error", "--max-time", "2", state.url .. "/global/health" }
assert(vim.v.shell_error == 0 and response:find("healthy", 1, true), response)

local old_generation, old_backend = state.generation, state.backend.pid
local old_port = state.port
assert(vim.uv.kill(old_backend, "sigkill"))
assert(vim.wait(2000, function()
  return process_dead(old_backend)
end, 20))
local replacement_requested = false
local replacement = assert(vim.uv.new_tcp())
assert(replacement:bind("127.0.0.1", old_port) == 0)
assert(replacement:listen(8, function(err)
  assert(not err, err)
  replacement_requested = true
end) == 0)
local recovered, recover_err = await(vim.g.opencode_opts.server.ensure)
assert(recovered, recover_err)
state = assert(lifecycle.read_state())
assert(state.transport == "loopback-http" and state.generation ~= old_generation)
assert(state.backend.pid ~= old_backend and state.backend.port == state.port)
assert(state.port ~= old_port, "direct recovery adopted a replacement listener")
assert(not replacement_requested, "direct recovery sent health to a replacement listener")
replacement:close()
assert(not vim.uv.fs_stat(lifecycle.paths().tls), "direct recovery created TLS material")

local function stop_state(active)
  local lock_ok, lock_err = await(lifecycle.acquire_lock)
  assert(lock_ok, lock_err)
  local stopped, stop_err = await(function(done)
    lifecycle.stop_pair(active, vim.uv.hrtime() + 8000 * 1000000, done)
  end, 10000)
  assert(stopped, stop_err)
  assert(process_dead(active.backend.pid))
  assert(vim.uv.fs_unlink(lifecycle.paths().state))
  lifecycle.release_lock()
end

stop_state(state)

local direct_password = "direct-test-password-not-for-output"
vim.fn.writefile(
  { vim.json.encode {
    tls_proxy = false,
    username = "direct-user",
    password = direct_password,
  } },
  server_config
)
assert(vim.uv.fs_chmod(server_config, 384))
assert(lifecycle.load_server_config())
local authenticated, authenticated_err = await(vim.g.opencode_opts.server.ensure)
assert(authenticated, authenticated_err)
state = assert(lifecycle.read_state())
local unauthenticated_code = vim.fn.system {
  "curl",
  "--silent",
  "--output",
  "/dev/null",
  "--write-out",
  "%{http_code}",
  state.url .. "/global/health",
}
assert(vim.v.shell_error == 0 and unauthenticated_code == "401", "direct unauthenticated request was not rejected")
local authenticated_code = vim.fn.system(
  { "curl", "--config", "-" },
  table.concat({
    "silent",
    'user = "direct-user:' .. direct_password .. '"',
    'output = "/dev/null"',
    'write-out = "%{http_code}"',
    'url = "' .. state.url .. '/global/health"',
  }, "\n")
)
assert(vim.v.shell_error == 0 and authenticated_code == "200", "direct authenticated request failed")
local encoded_state = table.concat(vim.fn.readfile(lifecycle.paths().state), "\n")
assert(not encoded_state:find(direct_password, 1, true), "direct password leaked into lifecycle state")
local backend_argv = table.concat(vim.fn.readfile("/proc/" .. state.backend.pid .. "/cmdline", "b"), "\n")
assert(not backend_argv:find(direct_password, 1, true), "direct password leaked into backend argv")
stop_state(state)

local conflict = assert(vim.uv.new_tcp())
assert(conflict:bind("127.0.0.1", 0) == 0 and conflict:listen(1, function() end) == 0)
local conflict_port = conflict:getsockname().port
vim.fn.writefile({ vim.json.encode { tls_proxy = false, port = conflict_port } }, server_config)
assert(vim.uv.fs_chmod(server_config, 384))
assert(lifecycle.load_server_config())
local conflict_ok, conflict_err = await(vim.g.opencode_opts.server.ensure, 5000)
assert(not conflict_ok and conflict_err:find("occupied", 1, true), conflict_err)
assert(lifecycle.read_state() == nil, "direct configured-port conflict published state")
assert(not vim.uv.fs_stat(lifecycle.paths().tls), "direct configured-port conflict created TLS material")
conflict:close()

vim.fn.writefile({ vim.json.encode { tls_proxy = false } }, server_config)
assert(vim.uv.fs_chmod(server_config, 384))
assert(lifecycle.load_server_config())
local spawns_before_failure = #vim.fn.readfile(spawn_log)
vim.g.mkchad_opencode_test_fail_pending_write = true
vim.g.mkchad_opencode_test_pidfd_helper = vim.fs.joinpath(root, "missing-pidfd-helper.py")
local pending_ok, pending_err = await(vim.g.opencode_opts.server.ensure, 5000)
assert(not pending_ok and pending_err:find("injected pending write failure", 1, true), pending_err)
assert(pending_err:find("pidfd signal helper is unavailable", 1, true), pending_err)
local spawn_records = vim.fn.readfile(spawn_log)
assert(#spawn_records == spawns_before_failure + 1, "failed direct pending publication launched a replacement backend")
local untracked_pid = assert(tonumber(spawn_records[#spawn_records]))
assert(not process_dead(untracked_pid), "pending failure fixture did not retain the cleanup-refused backend")
local launch_intent = assert(lifecycle.read_launch_intent())
assert(launch_intent.role == "backend" and launch_intent.pid == untracked_pid)
local blocked_ok, blocked_err = await(vim.g.opencode_opts.server.ensure, 3000)
assert(not blocked_ok and blocked_err:find("unresolved backend launch intent", 1, true), blocked_err)
assert(#vim.fn.readfile(spawn_log) == #spawn_records, "unresolved launch intent allowed another backend spawn")
assert(lifecycle.read_state() == nil and not vim.uv.fs_stat(lifecycle.paths().pending))
assert(vim.uv.kill(untracked_pid, "sigkill"))
assert(
  vim.wait(2000, function()
    return process_dead(untracked_pid)
  end, 20),
  "pending failure fixture backend did not stop"
)
local intent_lock_ok, intent_lock_err = await(lifecycle.acquire_lock, 3000)
assert(intent_lock_ok, intent_lock_err)
assert(lifecycle.remove_matching_launch_intent(launch_intent.generation))
lifecycle.release_lock()
assert(lifecycle.read_launch_intent() == nil)
vim.g.mkchad_opencode_test_fail_pending_write = nil
vim.g.mkchad_opencode_test_pidfd_helper = nil
vim.uv.fs_unlink(server_config)

print "opencode direct lifecycle tests passed"
