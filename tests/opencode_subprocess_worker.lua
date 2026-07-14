local config = assert(arg[1], "pass the MkChad config path")
local mode = assert(arg[2], "pass a worker mode")
local control = assert(arg[3], "pass a control path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
vim.notify = function() end

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { n = select("#", ...), ... }
  end)
  assert(vim.wait(timeout or 5000, function()
    return done
  end, 10), mode .. " timed out")
  return unpack(values, 1, values.n)
end

local function acquire()
  local locked, lock_err = await(lifecycle.acquire_lock, 3000)
  assert(locked, lock_err)
end

local function fd_count()
  return #vim.fn.glob("/proc/" .. vim.fn.getpid() .. "/fd/*", true, true)
end

local function child_count()
  local content = table.concat(vim.fn.readfile("/proc/" .. vim.fn.getpid() .. "/task/" .. vim.fn.getpid() .. "/children"), "")
  return #vim.split(content, "%s+", { trimempty = true })
end

local function assert_reaped(result)
  assert(result and result.pid and not vim.uv.fs_stat("/proc/" .. result.pid), "bounded child was not reaped")
end

if mode == "contender" then
  local locked, lock_err = await(lifecycle.acquire_lock, 3000)
  assert(locked, lock_err)
  lifecycle.release_lock()
  vim.fn.writefile({ "acquired" }, control)
  vim.cmd("qa!")
end

if mode == "holder" then
  acquire()
  vim.fn.writefile({ "held" }, control .. ".marker")
  local command = vim.fs.joinpath(vim.env.MKCHAD_SUBPROCESS_BIN, "keytool")
  local result, err = await(function(done)
    lifecycle.run_subprocess({ command, "direct-holder" }, {
      timeout_ms = 400,
      env = {
        MKCHAD_SUBPROCESS_PHASE = "direct-holder",
        MKCHAD_SUBPROCESS_RESIST_TERM = "1",
        MKCHAD_SUBPROCESS_PID = control .. ".pid",
      },
    }, done)
  end)
  assert(err and result.timed_out and result.killed, err)
  assert_reaped(result)
  lifecycle.release_lock()
  vim.fn.writefile({ "released" }, control)
  vim.cmd("qa!")
end

if mode == "shutdown" then
  acquire()
  local command = vim.fs.joinpath(vim.env.MKCHAD_SUBPROCESS_BIN, "java")
  lifecycle.run_subprocess({ command, "direct-shutdown" }, {
    timeout_ms = 5000,
    env = {
      MKCHAD_SUBPROCESS_PHASE = "direct-shutdown",
      MKCHAD_SUBPROCESS_RESIST_TERM = "1",
      MKCHAD_SUBPROCESS_PID = control .. ".pid",
    },
  }, function()
    error("shutdown subprocess callback unexpectedly ran")
  end)
  assert(vim.wait(2000, function()
    return vim.uv.fs_stat(control .. ".pid") ~= nil
  end, 10), "shutdown child did not start")
  vim.cmd("qa!")
end

local bin = assert(vim.env.MKCHAD_SUBPROCESS_BIN)
local before_fds = fd_count()
local before_children = child_count()
for _, executable in ipairs({ "opencode", "java", "keytool" }) do
  acquire()
  local command = vim.fs.joinpath(bin, executable)
  local phase = "direct-" .. executable
  local started = vim.uv.hrtime()
  local result, err = await(function(done)
    lifecycle.run_subprocess({ command, phase }, {
      timeout_ms = 400,
      env = {
        MKCHAD_SUBPROCESS_PHASE = phase,
        MKCHAD_SUBPROCESS_RESIST_TERM = "1",
        MKCHAD_SUBPROCESS_PID = control .. "." .. executable .. ".pid",
      },
    }, done)
  end)
  assert(err and result.timed_out and result.killed, err)
  assert((vim.uv.hrtime() - started) / 1000000 < 1500, executable .. " timeout exceeded its bound")
  assert_reaped(result)
  lifecycle.release_lock()
end

for _, stream in ipairs({ "stdout", "stderr" }) do
  acquire()
  local result, err = await(function(done)
    lifecycle.run_subprocess({ vim.fs.joinpath(bin, "keytool"), "direct-" .. stream }, {
      timeout_ms = 2000,
      env = { MKCHAD_SUBPROCESS_PHASE = "direct-" .. stream },
    }, done)
  end)
  assert(err and err:find("output limit", 1, true), err)
  assert(result and #result[stream] == 64 * 1024, "oversized " .. stream .. " was not capped")
  assert_reaped(result)
  lifecycle.release_lock()
end

acquire()
local _, missing_err = await(function(done)
  lifecycle.run_subprocess({ vim.fs.joinpath(bin, "does-not-exist") }, { timeout_ms = 400 }, done)
end)
assert(missing_err and missing_err:find("unable to start", 1, true), missing_err)
lifecycle.release_lock()

acquire()
local completion_count = 0
lifecycle.run_subprocess({ vim.fs.joinpath(bin, "keytool"), "direct-success" }, {}, function(_, err)
  assert(not err, err)
  completion_count = completion_count + 1
  lifecycle.release_lock()
end)
assert(vim.wait(3000, function()
  return completion_count == 1
end, 10), "bounded subprocess did not complete")
vim.wait(100, function()
  return false
end, 10)
assert(completion_count == 1, "bounded subprocess completed more than once")

acquire()
lifecycle.run_subprocess({ vim.fs.joinpath(bin, "keytool"), "direct-success" }, {}, function()
  error("intentional callback failure")
end)
assert(vim.wait(3000, function()
  return not lifecycle.fence_is_held()
end, 10), "callback exception retained the lifecycle fence")
acquire()
lifecycle.release_lock()

local phases = {
  "generate-mkchad-ca",
  "export-ca",
  "generate-server",
  "certificate-request",
  "sign-server",
  "import-mkchad-ca",
  "import-server",
  "validate-mkchad-ca",
  "validate-server",
  "java-validate",
}
for _, phase in ipairs(phases) do
  acquire()
  vim.env.MKCHAD_SUBPROCESS_PHASE = phase
  vim.env.MKCHAD_SUBPROCESS_RESIST_TERM = "1"
  vim.env.MKCHAD_SUBPROCESS_PID = control .. "." .. phase .. ".pid"
  local started = vim.uv.hrtime()
  local identity, err = await(function(done)
    lifecycle.ensure_certificate_material(vim.uv.hrtime() + 900 * 1000000, done)
  end, 2500)
  assert(not identity and err and err:find("timed out", 1, true), phase .. ": " .. tostring(err))
  assert((vim.uv.hrtime() - started) / 1000000 < 2000, phase .. " exceeded its documented bound")
  lifecycle.release_lock()
  assert(not vim.uv.fs_stat(lifecycle.paths().tls), phase .. " published certificate material")
  assert(not vim.uv.fs_stat(lifecycle.paths().state), phase .. " published lifecycle state")
  assert(not vim.uv.fs_stat(lifecycle.paths().pending), phase .. " published pending state")
  assert(#vim.fn.glob(lifecycle.paths().tls .. ".new-*", true, true) == 0, phase .. " left certificate staging")
end
vim.env.MKCHAD_SUBPROCESS_PHASE = nil
vim.env.MKCHAD_SUBPROCESS_RESIST_TERM = nil
vim.env.MKCHAD_SUBPROCESS_PID = nil

local function ensure_failure(label, timeout)
  vim.g.mkchad_opencode_test_timeout_ms = 900
  local ok, err = await(vim.g.opencode_opts.server.ensure, timeout or 4000)
  vim.g.mkchad_opencode_test_timeout_ms = nil
  assert(not ok and err, label .. " unexpectedly succeeded")
  assert(not lifecycle.fence_is_held(), label .. " retained the lifecycle fence")
  assert(not vim.uv.fs_stat(lifecycle.paths().state), label .. " published lifecycle state")
  assert(not vim.uv.fs_stat(lifecycle.paths().pending), label .. " published pending state")
  acquire()
  lifecycle.release_lock()
  return err
end

vim.env.MKCHAD_SUBPROCESS_PHASE = "generate-mkchad-ca"
vim.env.MKCHAD_SUBPROCESS_RESIST_TERM = "1"
local timeout_err = ensure_failure("integrated certificate timeout")
assert(timeout_err:find("timed out", 1, true), timeout_err)
assert(not vim.uv.fs_stat(lifecycle.paths().tls), "certificate timeout published TLS material")
vim.env.MKCHAD_SUBPROCESS_PHASE = nil
vim.env.MKCHAD_SUBPROCESS_RESIST_TERM = nil

vim.env.MKCHAD_SUBPROCESS_EXIT_PHASE = "generate-mkchad-ca"
local nonzero_err = ensure_failure("integrated certificate nonzero exit")
assert(nonzero_err:find("exited with code 7", 1, true), nonzero_err)
assert(not vim.uv.fs_stat(lifecycle.paths().tls), "certificate nonzero exit published TLS material")
vim.env.MKCHAD_SUBPROCESS_EXIT_PHASE = nil

vim.env.MKCHAD_SUBPROCESS_EMPTY_PHASE = "version"
local parse_err = ensure_failure("integrated version parse failure")
assert(parse_err:find("malformed", 1, true), parse_err)
vim.env.MKCHAD_SUBPROCESS_EMPTY_PHASE = nil

local fake_opencode = vim.fs.joinpath(bin, "opencode")
local original_opencode = vim.fn.readfile(fake_opencode)
vim.fn.writefile({ "#!/does/not/exist", "exit 1" }, fake_opencode)
assert(vim.uv.fs_chmod(fake_opencode, 493))
local start_err = ensure_failure("integrated version start failure")
assert(start_err:find("unable to start", 1, true), start_err)
vim.fn.writefile(original_opencode, fake_opencode)
assert(vim.uv.fs_chmod(fake_opencode, 493))

acquire()
local executable, _, version_err = await(function(done)
  vim.env.MKCHAD_SUBPROCESS_PHASE = "version"
  vim.env.MKCHAD_SUBPROCESS_RESIST_TERM = "1"
  lifecycle.resolve_executable(vim.uv.hrtime() + 900 * 1000000, done)
end, 2500)
assert(not executable and version_err and version_err:find("timed out", 1, true), version_err)
lifecycle.release_lock()
vim.env.MKCHAD_SUBPROCESS_PHASE = nil
vim.env.MKCHAD_SUBPROCESS_RESIST_TERM = nil
assert(not vim.uv.fs_stat(lifecycle.paths().state) and not vim.uv.fs_stat(lifecycle.paths().pending))

vim.wait(100, function()
  return false
end, 10)
assert(fd_count() <= before_fds, ("bounded subprocess fd growth: %d -> %d"):format(before_fds, fd_count()))
assert(child_count() == before_children, ("bounded subprocess child growth: %d -> %d"):format(before_children, child_count()))
vim.fn.writefile({ "passed" }, control)
vim.cmd("qa!")
