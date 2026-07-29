local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()
assert(lifecycle.strict_json_objects '{"protocol":1,"control":{"path":"/tmp/control.sock"}}')
assert(not lifecycle.strict_json_objects '{"protocol":1,"protocol":1}')
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
  assert(
    vim.wait(timeout or 3000, function()
      return done
    end, 10),
    "operation timed out"
  )
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
  {
    "missing proxy",
    function(s)
      s.proxy = nil
    end,
  },
  {
    "empty proxy",
    function(s)
      s.proxy = {}
    end,
  },
  {
    "missing backend",
    function(s)
      s.backend = nil
    end,
  },
  {
    "empty backend",
    function(s)
      s.backend = {}
    end,
  },
  {
    "fractional public port",
    function(s)
      s.port = 4096.5
    end,
  },
  {
    "wrong URL host",
    function(s)
      s.url = "https://localhost:4096"
    end,
  },
  {
    "relative CA",
    function(s)
      s.ca_path = "ca.pem"
    end,
  },
  {
    "bad generation",
    function(s)
      s.generation = "bad\ngeneration"
    end,
  },
  {
    "bad boot",
    function(s)
      s.boot_id = "not-a-boot-id"
    end,
  },
  {
    "bad timestamp",
    function(s)
      s.started_at = "2026-99-99T99:99:99Z"
    end,
  },
  {
    "bad certificate",
    function(s)
      s.certificate_identity = "not-sha256"
    end,
  },
  {
    "wrong proxy PID type",
    function(s)
      s.proxy.pid = "102"
    end,
  },
  {
    "wrong backend PID range",
    function(s)
      s.backend.pid = -1
    end,
  },
  {
    "empty proxy argv",
    function(s)
      s.proxy.argv = {}
    end,
  },
  {
    "non-string backend argv",
    function(s)
      s.backend.argv[1] = 7
    end,
  },
  {
    "missing runtime device",
    function(s)
      s.backend.process_executable_dev = nil
    end,
  },
  {
    "wrong runtime inode type",
    function(s)
      s.proxy.process_executable_ino = 4
    end,
  },
  {
    "relative executable",
    function(s)
      s.backend.executable = "opencode"
    end,
  },
  {
    "zero launch inode",
    function(s)
      s.backend.executable_ino = "0"
    end,
  },
  {
    "bad start time",
    function(s)
      s.backend.start_time = "0"
    end,
  },
  {
    "wrong backend log",
    function(s)
      s.backend.log = paths.proxy_log
    end,
  },
  {
    "wrong proxy source",
    function(s)
      s.proxy.source = "/tmp/opencode/other.java"
    end,
  },
  {
    "same role port",
    function(s)
      s.backend.port = s.proxy.port
    end,
  },
  {
    "wrong pinned backend PID",
    function(s)
      s.proxy.argv[10] = "999"
    end,
  },
  {
    "wrong backend host role",
    function(s)
      s.backend.argv[4] = "0.0.0.0"
    end,
  },
}

local schema3_tls = vim.deepcopy(complete)
schema3_tls.schema = 3
schema3_tls.transport = "tls-proxy"
for _, fixture in ipairs {
  { "schema-2 TLS", complete },
  { "schema-3 TLS", schema3_tls },
} do
  write_json(paths.state, fixture[2])
  assert(
    select(2, lifecycle.read_state()) == "valid",
    fixture[1] .. " state was rejected: " .. tostring(select(2, lifecycle.read_state()))
  )
  for _, test in ipairs(cases) do
    local state = vim.deepcopy(fixture[2])
    test[2](state)
    write_json(paths.state, state)
    local decoded, status = lifecycle.read_state()
    assert(decoded == nil and status == "malformed", fixture[1] .. " " .. test[1] .. " was accepted")

    local ok, err = pcall(lifecycle.show_info)
    assert(ok, fixture[1] .. " " .. test[1] .. " crashed info: " .. tostring(err))
    local reload_ok = await(lifecycle.reload_current_directory)
    assert(not reload_ok, fixture[1] .. " " .. test[1] .. " reached reload requests")

    local before = #notifications
    lifecycle.stop_shared_server()
    assert(
      vim.wait(3000, function()
        return #notifications > before
      end, 10),
      fixture[1] .. " " .. test[1] .. " stop did not finish"
    )

    vim.env.OPENCODE_PORT = "invalid"
    local ensure_ok, ensure_err = await(vim.g.opencode_opts.server.ensure)
    vim.env.OPENCODE_PORT = nil
    assert(
      not ensure_ok and ensure_err:find("must be an integer", 1, true),
      fixture[1] .. " " .. test[1] .. " ensure was not bounded"
    )
    assert(vim.uv.fs_stat("/proc/" .. vim.fn.getpid()), fixture[1] .. " " .. test[1] .. " affected the test process")
  end
end

local schema4 = vim.deepcopy(schema3_tls)
schema4.schema = 4
schema4.proxy.process_executable = "/usr/lib/jvm/java-21-openjdk/bin/java"
schema4.proxy.executable = "/usr/lib/jvm/java-21-openjdk/bin/java"
schema4.proxy.argv = {
  "/usr/lib/jvm/java-21-openjdk/bin/java",
  "--source",
  "21",
  paths.proxy_source,
  "--broker",
  "--state-root",
  paths.root,
  "--control",
  paths.control,
  "--generation",
  schema4.generation,
  "--boot-id",
  boot_id,
  "--backend-executable",
  backend.executable,
  "--backend-version",
  backend.local_version,
  "--backend-port",
  tostring(backend.port),
  "--listen-port",
  tostring(schema4.port),
  "--keystore",
  paths.server_store,
  "--password-file",
  paths.password,
  "--max-connections",
  "128",
  "--backend-log",
  paths.log,
  "--pidfd-python",
  paths.pidfd_python,
  "--pidfd-helper",
  paths.pidfd_helper,
}
schema4.broker = {
  protocol = 1,
  control_path = paths.control,
  control_dev = "18446744073709551615",
  control_ino = "6",
}
write_json(paths.state, schema4)
assert(select(2, lifecycle.read_state()) == "valid", "schema-4 TLS state was rejected")
for _, test in ipairs {
  {
    "missing broker",
    function(s)
      s.broker = nil
    end,
  },
  {
    "wrong broker protocol",
    function(s)
      s.broker.protocol = 2
    end,
    "unsupported broker protocol",
  },
  {
    "wrong control path",
    function(s)
      s.broker.control_path = "/tmp/control.sock"
    end,
  },
  {
    "legacy proxy argv",
    function(s)
      s.proxy.argv = vim.deepcopy(proxy_argv)
    end,
  },
} do
  local malformed = vim.deepcopy(schema4)
  test[2](malformed)
  write_json(paths.state, malformed)
  assert(select(2, lifecycle.read_state()) == (test[3] or "malformed"), "schema-4 " .. test[1] .. " was accepted")
end

for _, invalid in ipairs {
  { "missing" },
  { "Boolean", false },
  { "number", 1 },
  { "array", {} },
  { "object", { value = "tls-proxy" } },
  { "unknown string", "unknown" },
} do
  local malformed = vim.deepcopy(schema3_tls)
  malformed.transport = invalid[2]
  write_json(paths.state, malformed)
  assert(select(2, lifecycle.read_state()) == "malformed", "schema-3 TLS " .. invalid[1] .. " transport was accepted")
end

local direct = vim.deepcopy(complete)
direct.schema = 3
direct.transport = "loopback-http"
direct.port = direct.backend.port
direct.url = "http://127.0.0.1:" .. direct.port
direct.ca_path = nil
direct.certificate_identity = nil
direct.proxy = nil
write_json(paths.state, direct)
assert(select(2, lifecycle.read_state()) == "valid", "schema-3 direct state was rejected")
for _, test in ipairs {
  {
    "direct proxy",
    function(s)
      s.proxy = vim.deepcopy(proxy)
    end,
  },
  {
    "direct CA",
    function(s)
      s.ca_path = paths.ca
    end,
  },
  {
    "direct certificate",
    function(s)
      s.certificate_identity = string.rep("a", 64)
    end,
  },
  {
    "direct HTTPS URL",
    function(s)
      s.url = "https://127.0.0.1:" .. s.port
    end,
  },
  {
    "direct backend port",
    function(s)
      s.backend.port = s.port + 1
    end,
  },
} do
  local malformed = vim.deepcopy(direct)
  test[2](malformed)
  write_json(paths.state, malformed)
  assert(select(2, lifecycle.read_state()) == "malformed", test[1] .. " was accepted")
end

local future = { schema = 5, sentinel = "preserve" }
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
local pending_lock_ok, pending_lock_err = await(lifecycle.acquire_lock)
assert(pending_lock_ok, pending_lock_err)
local pending_cases = {
  {
    "empty backend",
    function(p)
      p.backend = {}
    end,
  },
  {
    "empty proxy",
    function(p)
      p.proxy = {}
    end,
  },
  {
    "wrong PID",
    function(p)
      p.backend.pid = vim.fn.getpid()
      p.backend.argv = "unsafe"
    end,
  },
  {
    "bad argv element",
    function(p)
      p.backend.argv[1] = {}
    end,
  },
  {
    "missing runtime inode",
    function(p)
      p.backend.process_executable_ino = nil
    end,
  },
  {
    "bad role port",
    function(p)
      p.proxy.argv[8] = "1"
    end,
  },
  {
    "future schema",
    function(p)
      p.schema = 4
    end,
  },
}
local function tls_pending(schema)
  return {
    schema = schema,
    hostname = complete.hostname,
    generation = complete.generation,
    boot_id = boot_id,
    backend = vim.deepcopy(backend),
    proxy = vim.deepcopy(proxy),
  }
end
for _, fixture in ipairs {
  { "schema-2 TLS", tls_pending(2) },
  { "schema-3 TLS", vim.tbl_extend("force", tls_pending(3), { schema = 3, transport = "tls-proxy" }) },
} do
  write_json(paths.pending, fixture[2])
  assert(select(2, lifecycle.read_pending()) == "valid", fixture[1] .. " pending metadata was rejected")
  for _, test in ipairs(pending_cases) do
    local pending = vim.deepcopy(fixture[2])
    test[2](pending)
    write_json(paths.pending, pending)
    local decoded, status = lifecycle.read_pending()
    assert(decoded == nil and status == "malformed", fixture[1] .. " pending " .. test[1] .. " was accepted")
    local cleaned, cleanup_err = await(function(done)
      lifecycle.cleanup_pending(vim.uv.hrtime() + 1000000000, done)
    end)
    assert(not cleaned and cleanup_err:find("malformed pending", 1, true), fixture[1] .. " pending cleanup was unsafe")
    assert(vim.uv.fs_stat(paths.pending), "malformed pending metadata was removed")
    assert(vim.uv.fs_stat("/proc/" .. vim.fn.getpid()), "malformed pending signaled the test process")
    vim.uv.fs_unlink(paths.pending)
  end
end
local direct_pending = {
  schema = 3,
  transport = "loopback-http",
  hostname = complete.hostname,
  generation = complete.generation,
  boot_id = boot_id,
  port = backend.port,
  backend = vim.deepcopy(backend),
}
write_json(paths.pending, direct_pending)
assert(select(2, lifecycle.read_pending()) == "valid", "schema-3 direct pending metadata was rejected")
for _, test in ipairs {
  {
    "proxy",
    function(p)
      p.proxy = vim.deepcopy(proxy)
    end,
  },
  {
    "missing port",
    function(p)
      p.port = nil
    end,
  },
  {
    "mismatched port",
    function(p)
      p.port = p.backend.port + 1
    end,
  },
  {
    "missing transport",
    function(p)
      p.transport = nil
    end,
  },
  {
    "unknown transport",
    function(p)
      p.transport = "unknown"
    end,
  },
} do
  local malformed = vim.deepcopy(direct_pending)
  test[2](malformed)
  write_json(paths.pending, malformed)
  assert(select(2, lifecycle.read_pending()) == "malformed", "direct pending metadata accepted " .. test[1])
end
for _, invalid in ipairs {
  { "missing" },
  { "Boolean", false },
  { "number", 1 },
  { "array", {} },
  { "object", { value = "tls-proxy" } },
  { "unknown string", "unknown" },
} do
  local malformed = tls_pending(3)
  malformed.transport = invalid[2]
  write_json(paths.pending, malformed)
  assert(
    select(2, lifecycle.read_pending()) == "malformed",
    "schema-3 TLS pending " .. invalid[1] .. " transport was accepted"
  )
end
vim.uv.fs_unlink(paths.pending)
lifecycle.release_lock()

local broker_intent = {
  schema = 2,
  transport = "tls-proxy",
  hostname = complete.hostname,
  generation = "broker-intent-generation",
  boot_id = boot_id,
  proxy = {
    role = "proxy",
    port = 4096,
    executable = "/usr/lib/jvm/java-21-openjdk/bin/java",
    executable_dev = "1",
    executable_ino = "4",
    source = paths.proxy_source,
    source_dev = "1",
    source_ino = "5",
    log = paths.proxy_log,
    argv = {
      "/usr/lib/jvm/java-21-openjdk/bin/java",
      "--source",
      "21",
      paths.proxy_source,
      "--broker",
      "--state-root",
      paths.root,
      "--control",
      paths.control,
      "--generation",
      "broker-intent-generation",
      "--boot-id",
      boot_id,
      "--backend-executable",
      backend.executable,
      "--backend-version",
      backend.local_version,
      "--backend-port",
      "55001",
      "--listen-port",
      "4096",
      "--keystore",
      paths.server_store,
      "--password-file",
      paths.password,
      "--max-connections",
      "128",
      "--backend-log",
      paths.log,
      "--pidfd-python",
      paths.pidfd_python,
      "--pidfd-helper",
      paths.pidfd_helper,
    },
  },
  public = { role = "public", port = 4096 },
  control = { protocol = 1, path = paths.control },
  backend = {
    role = "backend",
    executable = backend.executable,
    executable_dev = "1",
    executable_ino = "3",
    version = backend.local_version,
    port = 55001,
    log = paths.log,
  },
}
write_json(paths.launch, broker_intent)
assert(select(2, lifecycle.read_launch_intent()) == "valid", "exact schema-2 broker intent was rejected")
local malformed_intent = vim.deepcopy(broker_intent)
malformed_intent.backend.log = paths.proxy_log
write_json(paths.launch, malformed_intent)
assert(select(2, lifecycle.read_launch_intent()) == "malformed", "broker intent accepted a mismatched backend log")
local future_intent = { schema = 3, sentinel = "preserve-future-intent" }
write_json(paths.launch, future_intent)
assert(select(2, lifecycle.read_launch_intent()) == "unsupported schema", "future launch intent was not preserved")
assert(table.concat(vim.fn.readfile(paths.launch), ""):find("preserve-future-intent", 1, true))
vim.uv.fs_unlink(paths.launch)

assert(vim.uv.fs_chmod(paths.root, 493))
assert(vim.uv.fs_stat(paths.root).mode % 512 == 493, "fixture did not make authority root permissive")
assert(lifecycle.ensure_state_dir() == nil, "permissive authority root was accepted")
assert(vim.uv.fs_chmod(paths.root, 448))
assert(lifecycle.ensure_state_dir(), "restored private authority root was rejected")

vim.cmd "qa!"
