local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
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
local near_argv = vim.split(vim.fn.readfile("/proc/" .. near_pid .. "/cmdline", "b")[1], "\0", {
  plain = true,
  trimempty = true,
})
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

local auth_port = 49888
local auth_server = vim.uv.new_tcp()
assert(auth_server:bind("127.0.0.1", auth_port) == 0, "could not bind 401 fixture")
assert(auth_server:listen(8, function(err)
  assert(not err, err)
  local client = vim.uv.new_tcp()
  auth_server:accept(client)
  client:read_start(function()
    client:write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
    client:read_stop()
    client:close()
  end)
end))
local auth_job = vim.fn.jobstart({
  "python3",
  "-c",
  "import time; time.sleep(5)",
  "serve",
  "--hostname",
  "127.0.0.1",
  "--port",
  tostring(auth_port),
})
local auth_pid = vim.fn.jobpid(auth_job)
assert(vim.wait(1000, function()
  return vim.uv.fs_readlink("/proc/" .. auth_pid .. "/exe") ~= nil
end, 10), "401 fixture process did not exec")
local auth_state = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = auth_pid,
  generation = "401-test",
  host = "127.0.0.1",
  port = auth_port,
  url = "http://127.0.0.1:" .. auth_port,
  process_executable = vim.uv.fs_readlink("/proc/" .. auth_pid .. "/exe"),
  argv = vim.split(vim.fn.readfile("/proc/" .. auth_pid .. "/cmdline", "b")[1], "\0", { plain = true, trimempty = true }),
}
assert(lifecycle.write_state(auth_state))
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
vim.fn.jobstop(auth_job)
auth_server:close()

-- A simultaneous pair can create only one atomic lock directory. The second
-- worker is started by the shell harness below so this single process test
-- remains deterministic and does not depend on an OpenCode installation.
local acquired = wait_for(lifecycle.acquire_lock)
assert_equal(acquired, true, "first lock acquirer")
assert_equal(lifecycle.lock_is_owned(), true, "acquirer token revalidation")
lifecycle.release_lock()
assert_equal(vim.uv.fs_stat(lifecycle.paths().lock), nil, "owned lock release")

vim.cmd("qa!")
