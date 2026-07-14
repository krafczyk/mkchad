local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()
assert(vim.fn.mkdir(paths.root, "p", 448) ~= 0 or vim.uv.fs_stat(paths.root))

package.loaded["opencode.server"] = {}
local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 3000, function()
    return done
  end, 10), "operation timed out")
  return unpack(values)
end

local function write_json(path, value)
  vim.fn.writefile({ vim.json.encode(value) }, path)
  assert(vim.uv.fs_chmod(path, 384))
end

local boot_id = assert(lifecycle.current_boot_id())
local backend = {
  pid = 101,
  port = 55001,
  argv = { "/opt/opencode", "serve", "--hostname", "127.0.0.1", "--port", "55001" },
  process_executable = "/usr/bin/node",
  process_executable_dev = "1",
  process_executable_ino = "2",
  executable = "/opt/opencode",
  executable_dev = "1",
  executable_ino = "3",
  start_time = "123",
  local_version = "1.17.20",
  server_version = "1.17.20",
  log = paths.log,
}
local proxy_argv = {
  "/usr/bin/java",
  "--source",
  "21",
  paths.proxy_source,
  "--listen-port",
  "4096",
  "--backend-port",
  "55001",
  "--backend-pid",
  "101",
  "--backend-start",
  "123",
  "--boot-id",
  boot_id,
  "--keystore",
  paths.server_store,
  "--password-file",
  paths.password,
  "--max-connections",
  "128",
}
local proxy = {
  pid = 102,
  port = 4096,
  argv = proxy_argv,
  process_executable = "/usr/bin/java",
  process_executable_dev = "1",
  process_executable_ino = "4",
  executable = "/usr/bin/java",
  executable_dev = "1",
  executable_ino = "4",
  source = paths.proxy_source,
  source_dev = "1",
  source_ino = "5",
  start_time = "124",
  log = paths.proxy_log,
}
local complete = {
  schema = 2,
  hostname = (vim.uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_"),
  generation = "validation-generation",
  host = "127.0.0.1",
  port = 4096,
  url = "https://127.0.0.1:4096",
  port_source = "preferred 4096",
  started_at = "2026-07-14T12:34:56Z",
  cwd = "/tmp/opencode",
  boot_id = boot_id,
  ca_path = paths.ca,
  certificate_identity = string.rep("a", 64),
  proxy = proxy,
  backend = backend,
}

local cases = {
  { "missing proxy", function(s) s.proxy = nil end },
  { "empty proxy", function(s) s.proxy = {} end },
  { "missing backend", function(s) s.backend = nil end },
  { "empty backend", function(s) s.backend = {} end },
  { "fractional public port", function(s) s.port = 4096.5 end },
  { "wrong URL host", function(s) s.url = "https://localhost:4096" end },
  { "relative CA", function(s) s.ca_path = "ca.pem" end },
  { "bad generation", function(s) s.generation = "bad\ngeneration" end },
  { "bad boot", function(s) s.boot_id = "not-a-boot-id" end },
  { "bad timestamp", function(s) s.started_at = "2026-99-99T99:99:99Z" end },
  { "bad certificate", function(s) s.certificate_identity = "not-sha256" end },
  { "wrong proxy PID type", function(s) s.proxy.pid = "102" end },
  { "wrong backend PID range", function(s) s.backend.pid = -1 end },
  { "empty proxy argv", function(s) s.proxy.argv = {} end },
  { "non-string backend argv", function(s) s.backend.argv[1] = 7 end },
  { "missing runtime device", function(s) s.backend.process_executable_dev = nil end },
  { "wrong runtime inode type", function(s) s.proxy.process_executable_ino = 4 end },
  { "relative executable", function(s) s.backend.executable = "opencode" end },
  { "zero launch inode", function(s) s.backend.executable_ino = "0" end },
  { "bad start time", function(s) s.backend.start_time = "0" end },
  { "wrong backend log", function(s) s.backend.log = paths.proxy_log end },
  { "wrong proxy source", function(s) s.proxy.source = "/tmp/opencode/other.java" end },
  { "same role port", function(s) s.backend.port = s.proxy.port end },
  { "wrong pinned backend PID", function(s) s.proxy.argv[10] = "999" end },
  { "wrong backend host role", function(s) s.backend.argv[4] = "0.0.0.0" end },
}

for _, test in ipairs(cases) do
  local state = vim.deepcopy(complete)
  test[2](state)
  write_json(paths.state, state)
  local decoded, status = lifecycle.read_state()
  assert(decoded == nil and status == "malformed", test[1] .. " was accepted")

  local ok, err = pcall(lifecycle.show_info)
  assert(ok, test[1] .. " crashed info: " .. tostring(err))
  local reload_ok = await(lifecycle.reload_current_directory)
  assert(not reload_ok, test[1] .. " reached reload requests")

  local before = #notifications
  lifecycle.stop_shared_server()
  assert(vim.wait(3000, function()
    return #notifications > before
  end, 10), test[1] .. " stop did not finish")

  vim.env.OPENCODE_PORT = "invalid"
  local ensure_ok, ensure_err = await(vim.g.opencode_opts.server.ensure)
  vim.env.OPENCODE_PORT = nil
  assert(not ensure_ok and ensure_err:find("must be an integer", 1, true), test[1] .. " ensure was not bounded")
  assert(vim.uv.fs_stat("/proc/" .. vim.fn.getpid()), test[1] .. " affected the test process")
end

local future = { schema = 3, sentinel = "preserve" }
write_json(paths.state, future)
assert(select(2, lifecycle.read_state()) == "unsupported schema")
assert(pcall(lifecycle.show_info))
assert(not await(lifecycle.reload_current_directory))
local before = #notifications
lifecycle.stop_shared_server()
assert(vim.wait(3000, function()
  return #notifications > before
end, 10))
local future_ok, future_err = await(vim.g.opencode_opts.server.ensure)
assert(not future_ok and future_err:find("unsupported future", 1, true), future_err)
assert(table.concat(vim.fn.readfile(paths.state), ""):find("preserve", 1, true))

vim.uv.fs_unlink(paths.state)
local pending_cases = {
  { "empty backend", function(p) p.backend = {} end },
  { "empty proxy", function(p) p.proxy = {} end },
  { "wrong PID", function(p) p.backend.pid = vim.fn.getpid(); p.backend.argv = "unsafe" end },
  { "bad argv element", function(p) p.backend.argv[1] = {} end },
  { "missing runtime inode", function(p) p.backend.process_executable_ino = nil end },
  { "bad role port", function(p) p.proxy.argv[8] = "1" end },
  { "future schema", function(p) p.schema = 3 end },
}
for _, test in ipairs(pending_cases) do
  local pending = {
    schema = 2,
    hostname = complete.hostname,
    generation = complete.generation,
    boot_id = boot_id,
    backend = vim.deepcopy(backend),
    proxy = vim.deepcopy(proxy),
  }
  test[2](pending)
  write_json(paths.pending, pending)
  local decoded, status = lifecycle.read_pending()
  assert(decoded == nil and status == "malformed", "pending " .. test[1] .. " was accepted")
  local cleaned, cleanup_err = await(function(done)
    lifecycle.cleanup_pending(vim.uv.hrtime() + 1000000000, done)
  end)
  assert(not cleaned and cleanup_err:find("malformed pending", 1, true), "pending " .. test[1] .. " cleanup was unsafe")
  assert(vim.uv.fs_stat(paths.pending), "malformed pending metadata was removed")
  assert(vim.uv.fs_stat("/proc/" .. vim.fn.getpid()), "pending " .. test[1] .. " signaled the test process")
  vim.uv.fs_unlink(paths.pending)
end

vim.cmd("qa!")
