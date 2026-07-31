-- Run with isolated XDG paths.  This is intentionally direct mode so the
-- command contract can be exercised without Java or a container runtime.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
local entrypoint = vim.fs.joinpath(root, "lua", "mkchad", "opencode", "command.lua")
local state_home = assert(vim.env.XDG_STATE_HOME, "set XDG_STATE_HOME to an isolated test path")
local config_home = assert(vim.env.XDG_CONFIG_HOME, "set XDG_CONFIG_HOME to an isolated test path")
local runtime_home = assert(vim.env.XDG_RUNTIME_DIR, "set XDG_RUNTIME_DIR to an isolated test path")
local nvim = assert(vim.fn.exepath "nvim" ~= "" and vim.fn.exepath "nvim")
local fake_bin = vim.fs.joinpath(state_home, "fake-bin")
local config_dir = vim.fs.joinpath(config_home, "mkchad")
local server_config = vim.fs.joinpath(config_dir, "opencode-server.json")
local data_home = vim.fs.joinpath(state_home, "protected-data")
local cache_home = vim.fs.joinpath(state_home, "protected-cache")
local lifecycle_host = (vim.uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_")
local lifecycle_root = vim.fs.joinpath(state_home, "mkchad", "opencode", lifecycle_host)

assert(vim.fn.mkdir(fake_bin, "p", 448) ~= 0 or vim.uv.fs_stat(fake_bin))
assert(vim.fn.mkdir(config_dir, "p", 448) ~= 0 or vim.uv.fs_stat(config_dir))
assert(vim.fn.mkdir(runtime_home, "p", 448) ~= 0 or vim.uv.fs_stat(runtime_home))
assert(vim.fn.mkdir(data_home, "p", 448) ~= 0 or vim.uv.fs_stat(data_home))
assert(vim.fn.mkdir(cache_home, "p", 448) ~= 0 or vim.uv.fs_stat(cache_home))
local credential = vim.fs.joinpath(data_home, "opencode-credential")
local cache_marker = vim.fs.joinpath(cache_home, "unrelated-cache")
vim.fn.writefile({ "must-survive-lifecycle-reset" }, credential)
vim.fn.writefile({ "must-survive-lifecycle-reset" }, cache_marker)

local fake = vim.fs.joinpath(fake_bin, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('standalone-test'); raise SystemExit(0)",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen(32)",
  "def serve(client):",
  "  with client:",
  "    while True:",
  "      request = b''",
  "      while b'\\r\\n\\r\\n' not in request:",
  "        part = client.recv(4096)",
  "        if not part: return",
  "        request += part",
  '      body = b\'{\\"healthy\\":true,\\"version\\":\\"standalone-test\\"}\'',
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=serve, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
local port_probe = assert(vim.uv.new_tcp())
assert(port_probe:bind("127.0.0.1", 0) == 0)
local test_port = assert(port_probe:getsockname().port)
port_probe:close()
vim.fn.writefile({ vim.json.encode { tls_proxy = false, port = test_port } }, server_config)
assert(vim.uv.fs_chmod(server_config, 384))

local environment = vim.fn.environ()
environment.HOME = vim.env.HOME
environment.XDG_CONFIG_HOME = config_home
environment.XDG_STATE_HOME = state_home
environment.XDG_RUNTIME_DIR = runtime_home
environment.XDG_DATA_HOME = data_home
environment.XDG_CACHE_HOME = cache_home
environment.OPENCODE_PORT = ""
environment.PATH = fake_bin .. ":" .. environment.PATH

local function invoke(...)
  local done, result = false, nil
  vim.system({
    nvim,
    "--headless",
    "-u",
    "NONE",
    "--cmd",
    "set rtp^=" .. root,
    "-l",
    entrypoint,
    "--",
    ...,
  }, { env = environment }, function(value)
    result, done = value, true
  end)
  assert(
    vim.wait(40000, function()
      return done
    end, 20),
    "standalone command timed out"
  )
  return result
end

local function process_dead(pid)
  if not vim.uv.fs_stat("/proc/" .. pid) then
    return true
  end
  local stat = table.concat(vim.fn.readfile("/proc/" .. pid .. "/stat"), "")
  return stat:match "%)%s+Z" ~= nil
end

local function artifact_paths()
  return {
    vim.fs.joinpath(lifecycle_root, "state.json"),
    vim.fs.joinpath(lifecycle_root, "pending.json"),
    vim.fs.joinpath(lifecycle_root, "launch.json"),
    vim.fs.joinpath(lifecycle_root, "control.sock"),
    vim.fs.joinpath(lifecycle_root, "control.quarantine"),
    vim.fs.joinpath(lifecycle_root, "server.log"),
    vim.fs.joinpath(lifecycle_root, "proxy.log"),
    vim.fs.joinpath(lifecycle_root, "startup.lock"),
    vim.fs.joinpath(lifecycle_root, "startup.lock.stale-fixture"),
    vim.fs.joinpath(lifecycle_root, "tls"),
    vim.fs.joinpath(lifecycle_root, "tls.new-stale-fixture"),
    vim.fs.joinpath(lifecycle_root, "tls.invalid-stale-fixture"),
  }
end

local function assert_reset_removed()
  for _, path in ipairs(artifact_paths()) do
    assert(not vim.uv.fs_lstat(path), "reset retained " .. path)
  end
  assert(vim.uv.fs_lstat(vim.fs.joinpath(lifecycle_root, "lifecycle.fence")), "reset removed its active fence")
  assert(table.concat(vim.fn.readfile(credential), "\n") == "must-survive-lifecycle-reset")
  assert(table.concat(vim.fn.readfile(cache_marker), "\n") == "must-survive-lifecycle-reset")
end

local function clear_and_assert_reset()
  local result = invoke("clear", "--json")
  assert(result.code == 0 and result.stdout:match "^%b{}\n$", result.stderr)
  local decoded = vim.json.decode(result.stdout)
  assert(decoded.ok and decoded.command == "clear" and decoded.status == "inactive")
  assert_reset_removed()
  return decoded
end

local function write_stale_artifacts()
  assert(vim.fn.mkdir(vim.fs.joinpath(lifecycle_root, "tls"), "p", 448) ~= 0)
  assert(vim.fn.mkdir(vim.fs.joinpath(lifecycle_root, "startup.lock.stale-fixture"), "p", 448) ~= 0)
  assert(vim.fn.mkdir(vim.fs.joinpath(lifecycle_root, "tls.new-stale-fixture"), "p", 448) ~= 0)
  assert(vim.fn.mkdir(vim.fs.joinpath(lifecycle_root, "tls.invalid-stale-fixture"), "p", 448) ~= 0)
  for _, name in ipairs {
    "state.json",
    "pending.json",
    "launch.json",
    "control.sock",
    "control.quarantine",
    "server.log",
    "proxy.log",
  } do
    vim.fn.writefile({ "{" }, vim.fs.joinpath(lifecycle_root, name))
  end
  vim.fn.writefile({ "stale TLS material" }, vim.fs.joinpath(lifecycle_root, "tls", "ca.pem"))
  vim.fn.writefile({ "staged TLS material" }, vim.fs.joinpath(lifecycle_root, "tls.new-stale-fixture", "ca.pem"))
  vim.fn.writefile({ "invalid TLS material" }, vim.fs.joinpath(lifecycle_root, "tls.invalid-stale-fixture", "ca.pem"))
  vim.fn.writefile({ "stale lock owner" }, vim.fs.joinpath(lifecycle_root, "startup.lock.stale-fixture", "owner.json"))
end

local inactive = invoke("status", "--json")
assert(inactive.code == 0 and inactive.stdout:match "^%b{}\n$", inactive.stderr)
assert(#inactive.stdout < 60 * 1024, "status JSON exceeded the command output bound")
local inactive_result = vim.json.decode(inactive.stdout)
assert(
  inactive_result.ok and inactive_result.status == "inactive" and inactive_result.state == vim.NIL,
  inactive.stdout .. inactive.stderr
)
assert(
  inactive_result.inventory and inactive_result.inventory.schema == 1 and #inactive_result.inventory.components == 14
)
for _, diagnostic in ipairs(inactive_result.inventory.diagnostics) do
  assert(diagnostic.code ~= "collector_internal_error", "collector discarded completed probe evidence")
end
assert(not vim.uv.fs_stat(vim.fs.joinpath(state_home, "mkchad", "opencode")), "inactive status created lifecycle state")
local host_evidence = vim.base64
  .encode(vim.json.encode {
    schema = 1,
    container_runtime = { state = "present", family = "apptainer", version = "1.3.0" },
    selected_image = { state = "absent" },
    persisted_instance = { state = "absent" },
  })
  :gsub("%+", "-")
  :gsub("/", "_")
  :gsub("=", "")
local host_status = invoke("status", "--json", "--host-evidence-v1", host_evidence)
local host_result = vim.json.decode(host_status.stdout)
assert(host_status.code == 0 and host_result.status == "inactive")
assert(host_result.inventory.observations[1].version == "1.3.0", "host evidence was not preserved")
local malformed_host = invoke("status", "--json", "--host-evidence-v1", "unsafe-host-payload")
local malformed_result = vim.json.decode(malformed_host.stdout)
assert(malformed_host.code == 0 and malformed_result.status == "inactive" and malformed_result.inventory)
assert(
  malformed_result.inventory.diagnostics[1].code == "host_evidence_invalid",
  "invalid host evidence changed lifecycle"
)
local missing_host_payload = invoke("status", "--host-evidence-v1", "--json")
assert(missing_host_payload.code == 2, "host evidence consumed the following option as its payload")
assert(missing_host_payload.stderr:find("requires a base64url payload", 1, true))
local inactive_human = invoke "status"
assert(inactive_human.code == 0, inactive_human.stderr)
assert(inactive_human.stdout:find(
  table.concat({
    "Command status: inactive",
    "URL: inactive",
    "Transport: inactive",
    "Generation: inactive",
    "Server version: unknown",
  }, "\n"),
  1,
  true
) == 1, "inactive human lifecycle status changed")
assert(inactive_human.stdout:find("Inventory: partial", 1, true), "inactive inventory summary missing")
assert(
  inactive_human.stdout:find("Inventory active compatibility: unknown", 1, true),
  "inactive active-contract summary missing"
)

local started = invoke("start", "--json")
assert(started.code == 0 and started.stdout:match "^%b{}\n$", started.stderr)
local started_result = vim.json.decode(started.stdout)
assert(started_result.ok and started_result.status == "healthy")
assert(started_result.state.transport == "loopback-http" and started_result.state.ca_cert == vim.NIL)
assert(started_result.state.server_version == "standalone-test")
assert(started_result.state.url:match "^http://127%.0%.0%.1:%d+$")
local healthy_human = invoke "status"
assert(healthy_human.code == 0, healthy_human.stderr)
assert(healthy_human.stdout:find(
  table.concat({
    "Command status: healthy",
    "URL: " .. started_result.state.url,
    "Transport: loopback-http",
    "Generation: " .. started_result.state.generation,
    "Server version: standalone-test",
  }, "\n"),
  1,
  true
) == 1, "healthy human lifecycle status changed")
assert(healthy_human.stdout:find("Inventory: partial", 1, true), "healthy inventory summary missing")

local reused = invoke("start", "--json")
assert(reused.code == 0, reused.stderr)
assert(
  vim.json.decode(reused.stdout).state.generation == started_result.state.generation,
  "start did not reuse the generation"
)

local stopped = invoke("stop", "--json")
assert(stopped.code == 0 and vim.json.decode(stopped.stdout).status == "inactive", stopped.stderr)

-- `clear` removes residual ordinary-stop state without reaching unrelated XDG
-- data or cache, retaining only the active fence needed for serialization.
clear_and_assert_reset()

-- Clear is the explicit stale-authority override: malformed metadata and stale
-- control, log, TLS, and lock debris are removable after manual accounting.
write_stale_artifacts()
local blocked_status = invoke("status", "--json")
local blocked_result = vim.json.decode(blocked_status.stdout)
assert(
  blocked_status.code == 0
    and blocked_result.ok
    and blocked_result.status == "blocked"
    and blocked_result.inventory
    and #blocked_result.inventory.components == 14,
  blocked_status.stderr
)
for _, item in ipairs(blocked_result.inventory.observations) do
  if item.id == "opencode:persisted" then
    assert(item.state == "unavailable", "malformed authority was reported as absent")
  end
end
local malformed_kill = invoke("kill", "--json")
assert(malformed_kill.code == 1 and not vim.json.decode(malformed_kill.stdout).ok, malformed_kill.stderr)
assert(vim.uv.fs_stat(vim.fs.joinpath(lifecycle_root, "state.json")), "kill erased malformed authority")
local unsafe_nested = vim.fs.joinpath(lifecycle_root, "tls", "unexpected-directory")
assert(vim.fn.mkdir(unsafe_nested, "p", 448) ~= 0)
local unsafe_clear = invoke("clear", "--json")
assert(unsafe_clear.code == 1 and not vim.json.decode(unsafe_clear.stdout).ok, unsafe_clear.stderr)
assert(vim.uv.fs_stat(vim.fs.joinpath(lifecycle_root, "state.json")), "failed clear erased authority")
assert(vim.uv.fs_rmdir(unsafe_nested))
clear_and_assert_reset()

-- Future schemas and broker protocols remain authority across downgrades.
for _, future in ipairs {
  { path = "state.json", value = { schema = 5 } },
  { path = "state.json", value = { schema = 4, broker = { protocol = 2 } } },
  { path = "pending.json", value = { schema = 5 } },
  { path = "launch.json", value = { schema = 3 } },
} do
  local path = vim.fs.joinpath(lifecycle_root, future.path)
  vim.fn.writefile({ vim.json.encode(future.value) }, path)
  assert(vim.uv.fs_chmod(path, 384))
  local future_clear = invoke("clear", "--json")
  assert(future_clear.code == 1 and not vim.json.decode(future_clear.stdout).ok, future_clear.stderr)
  assert(vim.uv.fs_stat(path), "clear erased unsupported future authority")
  assert(vim.uv.fs_unlink(path))
end

-- Reset unlinks a substituted lifecycle-directory symlink without traversing
-- into its target.
local tls_target = vim.fs.joinpath(state_home, "outside-lifecycle-tls")
local tls_target_marker = vim.fs.joinpath(tls_target, "must-not-be-removed")
assert(vim.fn.mkdir(tls_target, "p", 448) ~= 0 or vim.uv.fs_stat(tls_target))
vim.fn.writefile({ "outside lifecycle root" }, tls_target_marker)
assert(vim.uv.fs_symlink(tls_target, vim.fs.joinpath(lifecycle_root, "tls")))
clear_and_assert_reset()
assert(table.concat(vim.fn.readfile(tls_target_marker), "\n") == "outside lifecycle root")

-- A valid uncovered launch intent is preserved while its recorded role is
-- live because it does not contain enough identity to authorize a signal.
started = invoke("start", "--json")
assert(started.code == 0, started.stderr)
local launch_only_record =
  vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(lifecycle_root, "state.json")), "\n"))
vim.fn.writefile({
  vim.json.encode {
    schema = 1,
    hostname = lifecycle_host,
    generation = launch_only_record.generation,
    boot_id = launch_only_record.boot_id,
    role = "backend",
    port = launch_only_record.backend.port,
    pid = launch_only_record.backend.pid,
  },
}, vim.fs.joinpath(lifecycle_root, "launch.json"))
assert(vim.uv.fs_chmod(vim.fs.joinpath(lifecycle_root, "launch.json"), 384))
assert(vim.uv.fs_unlink(vim.fs.joinpath(lifecycle_root, "state.json")))
local launch_clear = invoke("clear", "--json")
assert(launch_clear.code == 1 and not vim.json.decode(launch_clear.stdout).ok, launch_clear.stderr)
local launch_kill = invoke("kill", "--json")
assert(launch_kill.code == 1 and not vim.json.decode(launch_kill.stdout).ok, launch_kill.stderr)
assert(not process_dead(launch_only_record.backend.pid), "reset command signaled an uncovered launch role")
assert(vim.uv.kill(launch_only_record.backend.pid, "sigkill"))
assert(
  vim.wait(2000, function()
    return process_dead(launch_only_record.backend.pid)
  end, 20),
  "manual launch-role accounting did not stop the backend"
)
clear_and_assert_reset()

-- PID-less uncovered intent is crash-cut evidence, not proof of inactivity.
vim.fn.writefile({
  vim.json.encode {
    schema = 1,
    hostname = lifecycle_host,
    generation = "pidless-launch-generation",
    boot_id = launch_only_record.boot_id,
    role = "backend",
    port = test_port,
  },
}, vim.fs.joinpath(lifecycle_root, "launch.json"))
assert(vim.uv.fs_chmod(vim.fs.joinpath(lifecycle_root, "launch.json"), 384))
local pidless_kill = invoke("kill", "--json")
assert(pidless_kill.code == 1 and not vim.json.decode(pidless_kill.stdout).ok, pidless_kill.stderr)
assert(vim.uv.fs_stat(vim.fs.joinpath(lifecycle_root, "launch.json")), "kill erased PID-less launch intent")
clear_and_assert_reset()

-- Kill never signals an unverifiable PID or erases the record when validation
-- fails; the operator can account for that process, then explicitly clear.
started = invoke("start", "--json")
assert(started.code == 0, started.stderr)
local unverifiable_record =
  vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(lifecycle_root, "state.json")), "\n"))
unverifiable_record.backend.start_time = tostring(assert(tonumber(unverifiable_record.backend.start_time)) + 1)
vim.fn.writefile({ vim.json.encode(unverifiable_record) }, vim.fs.joinpath(lifecycle_root, "state.json"))
assert(vim.uv.fs_chmod(vim.fs.joinpath(lifecycle_root, "state.json"), 384))
local failed_kill = invoke("kill", "--json")
assert(failed_kill.code == 1 and failed_kill.stdout:match "^%b{}\n$", failed_kill.stderr)
assert(not vim.json.decode(failed_kill.stdout).ok, "kill accepted an unverifiable direct process")
assert(not process_dead(unverifiable_record.backend.pid), "kill signaled an unverifiable direct process")
assert(vim.uv.fs_stat(vim.fs.joinpath(lifecycle_root, "state.json")), "kill erased unverifiable authority")
assert(vim.uv.kill(unverifiable_record.backend.pid, "sigkill"))
assert(
  vim.wait(2000, function()
    return process_dead(unverifiable_record.backend.pid)
  end, 20),
  "manual accounting did not stop the unverifiable backend"
)
clear_and_assert_reset()

-- A validated live generation is never cleared. Kill uses the existing direct
-- validated shutdown path, then resets all lifecycle artifacts.
started = invoke("start", "--json")
assert(started.code == 0, started.stderr)
local refused = invoke("clear", "--json")
assert(refused.code == 1 and refused.stdout:match "^%b{}\n$", refused.stderr)
local refused_result = vim.json.decode(refused.stdout)
assert(not refused_result.ok and refused_result.command == "clear" and refused_result.status == "blocked")
assert(vim.uv.fs_stat(vim.fs.joinpath(lifecycle_root, "state.json")), "clear removed live authority")
local live_record = vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(lifecycle_root, "state.json")), "\n"))

local killed = invoke("kill", "--json")
assert(killed.code == 0 and killed.stdout:match "^%b{}\n$", killed.stderr)
local killed_result = vim.json.decode(killed.stdout)
assert(killed_result.ok and killed_result.command == "kill" and killed_result.status == "inactive")
assert(process_dead(live_record.backend.pid), "kill retained the validated direct backend")
assert_reset_removed()

-- Both reset commands are idempotent and preserve the schema-1 JSON contract.
for _, command in ipairs { "clear", "kill" } do
  local repeated = invoke(command, "--json")
  assert(repeated.code == 0 and repeated.stdout:match "^%b{}\n$", repeated.stderr)
  local result = vim.json.decode(repeated.stdout)
  assert(result.schema == 1 and result.ok and result.command == command and result.status == "inactive")
end

local clear_human = invoke "clear"
assert(clear_human.code == 0 and clear_human.stdout == "clear: inactive\n", clear_human.stderr)
local help = invoke "--help"
assert(help.code == 0 and help.stdout == table.concat({
  "Usage: mkchad-opencode-server start [--json]",
  "       mkchad-opencode-server status [--json] [--host-evidence-v1 BASE64URL]",
  "       mkchad-opencode-server stop [--json]",
  "       mkchad-opencode-server clear [--json]",
  "       mkchad-opencode-server kill [--json]",
  "       mkchad-opencode-server --help",
  "",
}, "\n"), help.stderr)
for _, argv in ipairs { { "start", "--json", "unexpected" }, { "clear", "--json", "unexpected" }, { "kill", "--bad" } } do
  local invalid = invoke(unpack(argv))
  assert(invalid.code == 2 and invalid.stdout == "", "usage failure emitted machine output")
end

print "opencode standalone command tests passed"
