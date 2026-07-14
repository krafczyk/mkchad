local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function proc_argv(pid)
  local fd = assert(vim.uv.fs_open("/proc/" .. pid .. "/cmdline", "r", 0))
  local size = vim.uv.fs_fstat(fd).size
  local content = assert(vim.uv.fs_read(fd, size == 0 and 8192 or size, 0))
  vim.uv.fs_close(fd)
  return vim.split(content, "\0", { plain = true, trimempty = true })
end

local function wait_for(callback)
  local done, result = false
  callback(function(...)
    result = { ... }
    done = true
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "timed out")
  return unpack(result)
end

local function health_listener(port, requests)
  local server = assert(vim.uv.new_tcp())
  assert(server:bind("127.0.0.1", port) == 0, "could not bind health fixture")
  assert(server:listen(8, function(err)
    assert(not err, err)
    local client = assert(vim.uv.new_tcp())
    server:accept(client)
    client:read_start(function(read_err, data)
      assert(not read_err, read_err)
      if data then
        if requests then
          table.insert(requests, data)
        end
        client:write("HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"healthy\":true}")
        client:read_stop()
        client:close()
      end
    end)
  end) == 0)
  return server
end

if vim.env.MKCHAD_OPENCODE_LOCK_WORKER == "1" then
  local acquired = wait_for(lifecycle.acquire_lock)
  if acquired then
    vim.fn.writefile({ tostring(vim.fn.getpid()) }, vim.env.MKCHAD_OPENCODE_RESULT .. "." .. vim.fn.getpid())
    vim.wait(400)
    lifecycle.release_lock()
    vim.cmd("qa!")
  end
  vim.cmd("cquit 1")
end

-- Exact argv matching refuses an otherwise live near-match and a port prefix.
local pid = vim.fn.getpid()
local executable = vim.uv.fs_readlink("/proc/" .. pid .. "/exe")
local command = vim.fn.readfile("/proc/" .. pid .. "/cmdline", "b")[1]
local argv = vim.split(command, "\0", { plain = true, trimempty = true })
local state = {
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = pid,
  port = 4096,
  process_executable = executable,
  argv = argv,
}
assert_equal(lifecycle.process_is_owned(state), false, "current nvim must not match opencode serve")

local near_job = vim.fn.jobstart({
  "python3",
  "-c",
  "import time; time.sleep(5)",
  "serve",
  "--hostname",
  "127.0.0.1",
  "--port",
  "40960",
})
assert(near_job > 0, "could not start near-match fixture")
local near_pid = vim.fn.jobpid(near_job)
assert(vim.wait(1000, function()
  return vim.uv.fs_readlink("/proc/" .. near_pid .. "/exe") ~= nil
end, 10), "near-match fixture did not exec")
local near_argv = proc_argv(near_pid)
local near_state = {
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = near_pid,
  port = 4096,
  process_executable = vim.uv.fs_readlink("/proc/" .. near_pid .. "/exe"),
  argv = near_argv,
}
assert_equal(lifecycle.process_is_owned(near_state), false, "port-prefix process must not be signalable")
near_state.argv[#near_state.argv] = "4096"
assert_equal(lifecycle.process_is_owned(near_state), false, "near-match argv must not be signalable")
vim.fn.jobstop(near_job)

local tui_creations = 0
local latest_tui_job
package.loaded["snacks.terminal"] = {
  get = function()
    tui_creations = tui_creations + 1
    local job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(30)" })
    latest_tui_job = job
    return {
      job = job,
      valid = function()
        return true
      end,
      close = function(self)
        vim.fn.jobstop(self.job)
      end,
    }, true
  end,
}
local tui_state = { url = "http://127.0.0.1:4096", generation = "tui-test" }
local tui_done = false
lifecycle.ensure_local_tui(tui_state, function(ok, err)
  assert(ok, err)
  tui_done = true
end)
assert(vim.wait(1000, function()
  return tui_done
end, 10), "initial local TUI was not created")
assert(vim.uv.kill(vim.fn.jobpid(latest_tui_job), "sigkill"))
assert(vim.wait(1000, function()
  return vim.fn.jobwait({ latest_tui_job }, 0)[1] ~= -1
end, 10), "SIGKILL fixture did not exit")
tui_done = false
lifecycle.ensure_local_tui(tui_state, function(ok, err)
  assert(ok, err)
  tui_done = true
end)
assert(vim.wait(1000, function()
  return tui_done
end, 10), "dead local TUI was not recreated")
assert_equal(tui_creations, 2, "SIGKILL must recreate the local TUI")
vim.fn.jobstop(latest_tui_job)

local conflict_port = 49887
local responder = vim.fs.joinpath(lifecycle.paths().root, "healthy.py")
assert(vim.fn.mkdir(lifecycle.paths().root, "p", 448) ~= 0 or vim.uv.fs_stat(lifecycle.paths().root))
vim.fn.writefile({
  "import socket, sys",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen()",
  "while True:",
  "  client, _ = sock.accept(); client.recv(4096); client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\n\\r\\n{\\\"healthy\\\":true}'); client.close()",
}, responder)
local conflict_job = vim.fn.jobstart({ "python3", responder, "serve", "--hostname", "127.0.0.1", "--port", tostring(conflict_port) })
local conflict_pid = vim.fn.jobpid(conflict_job)
assert(vim.wait(1000, function()
  return vim.uv.fs_readlink("/proc/" .. conflict_pid .. "/exe") ~= nil
end, 10), "explicit-conflict fixture did not exec")
assert(vim.wait(1000, function()
  return lifecycle.process_listens_on_port(conflict_pid, conflict_port)
end, 10), "explicit-conflict fixture did not listen")
local conflict_state = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = conflict_pid,
  generation = "explicit-conflict-test",
  host = "127.0.0.1",
  port = conflict_port,
  url = "http://127.0.0.1:" .. conflict_port,
  process_executable = vim.uv.fs_readlink("/proc/" .. conflict_pid .. "/exe"),
  argv = proc_argv(conflict_pid),
}
local conflict_owned, conflict_reason = lifecycle.process_is_owned(conflict_state)
assert(conflict_owned, conflict_reason .. ": " .. vim.inspect(conflict_state.argv))
assert(lifecycle.write_state(conflict_state))
vim.env.OPENCODE_PORT = "49886"
local conflict_done, conflict_ok, conflict_err = false, nil, nil
vim.g.opencode_opts.server.ensure(function(ok, err)
  conflict_ok, conflict_err, conflict_done = ok, err, true
end)
assert(vim.wait(3000, function()
  return conflict_done
end, 10), "explicit conflict ensure did not finish")
assert_equal(conflict_ok, false, "different explicit port must not attach")
assert(conflict_err:find("stop the shared server", 1, true), conflict_err)
assert_equal(lifecycle.read_state().generation, "explicit-conflict-test", "explicit conflict must not change state")
assert(vim.fn.jobwait({ conflict_job }, 0)[1] == -1, "explicit conflict must not replace the backend")
vim.fn.jobstop(conflict_job)
vim.env.OPENCODE_PORT = nil

local auth_port = 49888
local auth_requests = vim.fs.joinpath(lifecycle.paths().root, "auth-requests.log")
local auth_responder = vim.fs.joinpath(lifecycle.paths().root, "auth-responder.py")
vim.fn.writefile({
  "import socket, sys",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[1]))); sock.listen()",
  "while True:",
  "  client, _ = sock.accept(); raw = client.recv(8192)",
  "  with open(sys.argv[2], 'ab') as out: out.write(raw + b'\\n---\\n')",
  "  client.sendall(b'HTTP/1.1 401 Unauthorized\\r\\nContent-Length: 0\\r\\n\\r\\n'); client.close()",
}, auth_responder)
local auth_job = vim.fn.jobstart({
  "python3",
  auth_responder,
  tostring(auth_port),
  auth_requests,
  "serve",
  "--hostname",
  "127.0.0.1",
  "--port",
  tostring(auth_port),
})
local auth_pid = vim.fn.jobpid(auth_job)
assert(vim.wait(1000, function()
  return lifecycle.process_listens_on_port(auth_pid, auth_port)
end, 10), "401 fixture process did not listen")
local auth_state = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = auth_pid,
  generation = "401-test",
  host = "127.0.0.1",
  port = auth_port,
  url = "http://127.0.0.1:" .. auth_port,
  process_executable = vim.uv.fs_readlink("/proc/" .. auth_pid .. "/exe"),
  argv = proc_argv(auth_pid),
}
assert(lifecycle.write_state(auth_state))
vim.env.OPENCODE_SERVER_PASSWORD = "verified-listener-password"
local auth_done, auth_ok, auth_err = false, nil, nil
vim.g.opencode_opts.server.ensure(function(ok, err)
  auth_ok, auth_err, auth_done = ok, err, true
end)
assert(vim.wait(3000, function()
  return auth_done
end, 10), "401 ensure did not finish")
assert_equal(auth_ok, false, "401 must not trigger recovery")
assert(auth_err:find("authentication failed", 1, true), auth_err)
local persisted = lifecycle.read_state()
assert_equal(persisted.generation, "401-test", "401 must leave managed state unchanged")
assert(vim.fn.jobwait({ auth_job }, 0)[1] == -1, "401 must not replace the existing backend")
assert(table.concat(vim.fn.readfile(auth_requests), "\n"):lower():find("authorization: basic", 1, true), "verified listener did not receive auth")
vim.env.OPENCODE_SERVER_PASSWORD = nil
vim.fn.jobstop(auth_job)

-- A matching argv alone is insufficient: a separate healthy responder must
-- not turn a non-listening managed PID into an adopted backend.
local ownership_port = 49889
local ownership_requests = {}
local ownership_responder = health_listener(ownership_port, ownership_requests)
local ownership_job = vim.fn.jobstart({
  "python3",
  "-c",
  "import time; time.sleep(30)",
  "serve",
  "--hostname",
  "127.0.0.1",
  "--port",
  tostring(ownership_port),
})
local ownership_pid = vim.fn.jobpid(ownership_job)
assert(vim.wait(1000, function()
  return vim.uv.fs_readlink("/proc/" .. ownership_pid .. "/exe") ~= nil
end, 10), "non-listener fixture did not exec")
local ownership_state = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = ownership_pid,
  generation = "non-listening-owned-pid",
  host = "127.0.0.1",
  port = ownership_port,
  url = "http://127.0.0.1:" .. ownership_port,
  port_source = "test",
  started_at = "2026-07-14T00:00:00Z",
  log = lifecycle.paths().log,
  local_version = "test",
  process_executable = vim.uv.fs_readlink("/proc/" .. ownership_pid .. "/exe"),
  argv = proc_argv(ownership_pid),
}
assert(lifecycle.process_is_owned(ownership_state))
assert(not lifecycle.process_listens_on_port(ownership_pid, ownership_port), "fixture unexpectedly owns responder socket")
assert(lifecycle.write_state(ownership_state))
vim.env.OPENCODE_SERVER_PASSWORD = "must-not-reach-unverified-listener"
local ownership_done, ownership_ok, ownership_err = false, nil, nil
vim.g.opencode_opts.server.ensure(function(ok, err)
  ownership_done, ownership_ok, ownership_err = true, ok, err
end)
assert(vim.wait(3000, function()
  return ownership_done
end, 10), "non-listener ownership ensure did not finish")
assert_equal(ownership_ok, false, "non-listening PID must not be treated as a healthy managed server")
assert(ownership_err:find("Refusing to adopt a healthy unmanaged OpenCode endpoint", 1, true), ownership_err)
assert(ownership_err:find("does not own the listening socket", 1, true), ownership_err)
assert_equal(lifecycle.read_state().generation, ownership_state.generation, "unmanaged endpoint state must be preserved")
assert(vim.fn.jobwait({ ownership_job }, 0)[1] == -1, "non-listening process must not be signaled")
assert(#ownership_requests > 0, "unverified endpoint was not observed")
assert(not table.concat(ownership_requests):lower():find("authorization:", 1, true), "credentials reached an unverified listener")

for index = #ownership_requests, 1, -1 do
  table.remove(ownership_requests, index)
end
local original_notify = vim.notify
local original_server_module = package.loaded["opencode.server"]
package.loaded["opencode.server"] = {}
local info_done = false
vim.notify = function()
  info_done = true
end
lifecycle.show_info()
assert(vim.wait(3000, function()
  return #ownership_requests > 0 and info_done
end, 10), "observational info did not finish its unverified probe")
vim.notify = original_notify
package.loaded["opencode.server"] = original_server_module
assert(not table.concat(ownership_requests):lower():find("authorization:", 1, true), "info sent credentials to an unverified listener")

local stale_state = vim.deepcopy(ownership_state)
stale_state.pid = 99999999
local stale_done = false
lifecycle.managed_state_if_healthy(stale_state, nil, function()
  stale_done = true
end)
assert(stale_done, "stale state classification did not finish")
assert_equal(#ownership_requests, 1, "stale state must not probe an unverified endpoint with credentials")
vim.env.OPENCODE_SERVER_PASSWORD = nil
vim.fn.jobstop(ownership_job)
ownership_responder:close()
vim.uv.fs_unlink(lifecycle.paths().state)

-- Availability must include listen(), not merely bind(). When 4096 is free,
-- controlled HTTP and non-HTTP listeners exercise both kinds there. When a
-- host service already owns 4096, do not inspect it; it still must trigger the
-- same automatic fallback.
local preferred_port = 4096
local fallback, fallback_source
if lifecycle.port_is_available(preferred_port) then
  local unknown_healthy = health_listener(preferred_port)
  assert(not lifecycle.port_is_available(preferred_port), "unknown healthy listener must occupy 4096")
  fallback, fallback_source = lifecycle.select_port(nil)
  assert(fallback ~= preferred_port and fallback_source == "fallback", "healthy unknown 4096 must select a high fallback")
  unknown_healthy:close()
  local non_http = assert(vim.uv.new_tcp())
  assert(non_http:bind("127.0.0.1", preferred_port) == 0, "could not bind non-HTTP fixture")
  assert(non_http:listen(1, function() end) == 0)
  assert(not lifecycle.port_is_available(preferred_port), "non-HTTP listener must occupy 4096")
  fallback, fallback_source = lifecycle.select_port(nil)
  assert(fallback ~= preferred_port and fallback_source == "fallback", "non-HTTP 4096 must select a high fallback")
  non_http:close()
else
  fallback, fallback_source = lifecycle.select_port(nil)
  assert(fallback ~= preferred_port and fallback_source == "fallback", "occupied 4096 must select a high fallback")
end
local fixture_port = 49890
local unknown_healthy = health_listener(fixture_port)
assert(not lifecycle.port_is_available(fixture_port), "unknown healthy listener must occupy its port")
unknown_healthy:close()
local non_http = assert(vim.uv.new_tcp())
assert(non_http:bind("127.0.0.1", fixture_port) == 0, "could not bind non-HTTP fixture")
assert(non_http:listen(1, function() end) == 0)
assert(not lifecycle.port_is_available(fixture_port), "non-HTTP listener must occupy its port")
non_http:close()

-- A failed automatic candidate is explicitly excluded before retry selection,
-- so the bounded retry cannot select 4096 again even if its bind race clears.
local retry_port, retry_source = lifecycle.select_port(nil, { [preferred_port] = true })
assert(retry_port ~= preferred_port and retry_source == "fallback", "automatic retry must exclude its failed candidate")

-- A simultaneous pair can create only one atomic lock directory. The second
-- worker is started by the shell harness below so this single process test
-- remains deterministic and does not depend on an OpenCode installation.
local acquired = wait_for(lifecycle.acquire_lock)
assert_equal(acquired, true, "first lock acquirer")
assert_equal(lifecycle.lock_is_owned(), true, "acquirer token revalidation")
lifecycle.release_lock()
assert_equal(vim.uv.fs_stat(lifecycle.paths().lock), nil, "owned lock release")

-- Wall-clock jumps must not expire a valid boot-scoped monotonic lease.
assert(wait_for(lifecycle.acquire_lock), "clock-change fixture could not acquire lock")
local owner = vim.json.decode(table.concat(vim.fn.readfile(lifecycle.paths().lock_owner), "\n"))
owner.acquired_at_unix_ms = 9000000000000000
vim.fn.writefile({ vim.json.encode(owner) }, lifecycle.paths().lock_owner)
local future = os.time() + 30
assert(vim.uv.fs_utime(lifecycle.paths().lock, future, future))
local clock_contender, clock_err = wait_for(lifecycle.acquire_lock)
assert(not clock_contender and clock_err:find("already in progress", 1, true), clock_err)
assert(lifecycle.lock_is_owned(), "wall-clock metadata invalidated the monotonic lease")
lifecycle.release_lock()

local function remove_lock_fixture()
  vim.uv.fs_unlink(lifecycle.paths().lock_owner)
  vim.uv.fs_rmdir(lifecycle.paths().lock)
end

local function age_lock()
  local old = os.time() - 30
  assert(vim.uv.fs_utime(lifecycle.paths().lock, old, old))
end

-- Missing and malformed owner metadata get a publication grace period, then
-- stale in the same realtime clock domain as the directory mtime.
assert(vim.uv.fs_mkdir(lifecycle.paths().lock, 448))
local recent_missing, recent_missing_err = wait_for(lifecycle.acquire_lock)
assert(not recent_missing and recent_missing_err:find("already in progress", 1, true), recent_missing_err)
remove_lock_fixture()

assert(vim.uv.fs_mkdir(lifecycle.paths().lock, 448))
vim.fn.writefile({ "{" }, lifecycle.paths().lock_owner)
local recent_malformed, recent_malformed_err = wait_for(lifecycle.acquire_lock)
assert(not recent_malformed and recent_malformed_err:find("already in progress", 1, true), recent_malformed_err)
remove_lock_fixture()

assert(vim.uv.fs_mkdir(lifecycle.paths().lock, 448))
age_lock()
assert(wait_for(lifecycle.acquire_lock), "old ownerless lock was not reclaimed")
lifecycle.release_lock()

assert(vim.uv.fs_mkdir(lifecycle.paths().lock, 448))
vim.fn.writefile({ "{" }, lifecycle.paths().lock_owner)
age_lock()
assert(wait_for(lifecycle.acquire_lock), "old malformed lock was not reclaimed")
lifecycle.release_lock()

-- A prior-boot monotonic value is invalid as realtime metadata and falls back
-- to the bounded directory age instead of blocking startup indefinitely.
assert(vim.uv.fs_mkdir(lifecycle.paths().lock, 448))
local reboot_stat = assert(vim.uv.fs_stat(lifecycle.paths().lock))
vim.fn.writefile({ vim.json.encode({
  token = "prior-boot",
  pid = vim.fn.getpid(),
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  lock_dev = reboot_stat.dev,
  lock_ino = reboot_stat.ino,
  acquired_at_unix_ms = 9000000000000000,
  deadline_unix_ms = 9000000000015000,
}) }, lifecycle.paths().lock_owner)
age_lock()
assert(wait_for(lifecycle.acquire_lock), "reboot-like lock timestamp was not reclaimed")
lifecycle.release_lock()

-- A delayed writer is bound to the inode it created and cannot overwrite the
-- owner metadata of a replacement lock after stale reclamation.
assert(vim.uv.fs_mkdir(lifecycle.paths().lock, 448))
local delayed_stat = assert(vim.uv.fs_stat(lifecycle.paths().lock))
local delayed_claim = { token = "delayed-writer", dev = delayed_stat.dev, ino = delayed_stat.ino }
age_lock()
assert(wait_for(lifecycle.acquire_lock), "replacement lock was not acquired")
local published = lifecycle.publish_lock_owner(delayed_claim)
assert(not published, "delayed writer published into a replacement lock")
assert(lifecycle.lock_is_owned(), "delayed writer disturbed replacement ownership")
lifecycle.release_lock()

-- Owner publication failure must remove only the inode this process created.
local original_fs_open = vim.uv.fs_open
vim.uv.fs_open = function(path, flags, mode)
  if path == lifecycle.paths().lock_owner and flags == "wx" then
    return nil, "forced owner publication failure"
  end
  return original_fs_open(path, flags, mode)
end
local unpublished, unpublished_err = wait_for(lifecycle.acquire_lock)
vim.uv.fs_open = original_fs_open
assert(not unpublished and unpublished_err:find("forced owner publication failure", 1, true), unpublished_err)
assert_equal(vim.uv.fs_stat(lifecycle.paths().lock), nil, "unpublished lock was not safely cleaned")

vim.cmd("qa!")
