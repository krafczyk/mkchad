local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()
vim.env.OPENCODE_PORT = nil
assert(vim.fn.mkdir(paths.root, "p", 448) ~= 0 or vim.uv.fs_stat(paths.root))
local command_config_home = vim.fs.joinpath(paths.root, "command-config")
local command_config = vim.fs.joinpath(command_config_home, "mkchad", "opencode-server.json")
assert(vim.fn.mkdir(vim.fs.dirname(command_config), "p", 448) ~= 0 or vim.uv.fs_stat(vim.fs.dirname(command_config)))
vim.fn.writefile({ "{}" }, command_config)
assert(vim.uv.fs_chmod(command_config, 384))
vim.env.XDG_CONFIG_HOME = command_config_home

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { n = select("#", ...), ... }
  end)
  assert(
    vim.wait(timeout or 40000, function()
      return done
    end, 20),
    "operation timed out"
  )
  return unpack(values, 1, values.n)
end

local function dead(pid)
  local stat = vim.uv.fs_stat("/proc/" .. pid) and table.concat(vim.fn.readfile("/proc/" .. pid .. "/stat"), "")
  return not stat or stat:match "%)%s+Z" ~= nil
end

local function broker_intent(state)
  return {
    schema = 2,
    transport = "tls-proxy",
    hostname = state.hostname,
    generation = state.generation,
    boot_id = state.boot_id,
    proxy = {
      role = "proxy",
      port = state.proxy.port,
      executable = state.proxy.executable,
      executable_dev = state.proxy.executable_dev,
      executable_ino = state.proxy.executable_ino,
      source = state.proxy.source,
      source_dev = state.proxy.source_dev,
      source_ino = state.proxy.source_ino,
      log = state.proxy.log,
      argv = vim.deepcopy(state.proxy.argv),
      pid = state.proxy.pid,
    },
    public = { role = "public", port = state.port },
    control = { protocol = state.broker.protocol, path = state.broker.control_path },
    backend = {
      role = "backend",
      executable = state.backend.executable,
      executable_dev = state.backend.executable_dev,
      executable_ino = state.backend.executable_ino,
      version = state.backend.local_version,
      port = state.backend.port,
      log = state.backend.log,
    },
  }
end

local fake = vim.fs.joinpath(paths.root, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import os, socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('broker-fixture'); raise SystemExit(0)",
  "retry_marker = os.environ.get('MKCHAD_OPENCODE_FAIL_ONCE')",
  "if retry_marker and not os.path.exists(retry_marker): open(retry_marker, 'w').close(); raise SystemExit(0)",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen(32)",
  "def serve(client):",
  "  with client:",
  "    while True:",
  "      data = b''",
  "      while b'\\r\\n\\r\\n' not in data:",
  "        part = client.recv(4096)",
  "        if not part: return",
  "        data += part",
  '      body = b\'{\\"healthy\\":true,\\"version\\":\\"broker-fixture\\"}\'',
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=serve, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = paths.root .. ":" .. vim.env.PATH

-- A broker that fails activation must stop through its exact control authority,
-- remove only matching provisional metadata, and retry with new candidate ports.
local retry_marker = vim.fs.joinpath(paths.root, "broker-activation-failed-once")
vim.env.MKCHAD_OPENCODE_FAIL_ONCE = retry_marker
local started, start_err, state = await(lifecycle.ensure_server)
vim.env.MKCHAD_OPENCODE_FAIL_ONCE = nil
assert(started, start_err)
assert(vim.uv.fs_stat(retry_marker), "broker activation fixture did not fail once")
assert(
  not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.launch),
  "broker activation retry retained provisional metadata"
)
assert(state.schema == 4 and state.transport == "tls-proxy")

assert(state.broker.protocol == 1 and state.broker.control_path == paths.control)
assert(
  not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.launch),
  "broker startup retained provisional metadata"
)
local root_before = assert(vim.uv.fs_lstat(paths.root))
local control_before = assert(vim.uv.fs_lstat(paths.control))
assert(root_before.mode % 512 == 448 and control_before.mode % 512 == 384)
assert(
  tostring(control_before.dev) == state.broker.control_dev and tostring(control_before.ino) == state.broker.control_ino
)

local status, observed = await(lifecycle.observe_server)
assert(
  status == "healthy" and observed.generation == state.generation,
  "broker status did not reuse the running generation"
)
assert(lifecycle.set_test_procfs_authority(false))
status, observed = await(lifecycle.observe_server)
assert(status == "healthy" and observed.generation == state.generation, "restricted status used caller procfs")
local reused, reuse_err, same = await(lifecycle.ensure_server)
assert(reused, reuse_err)
assert(
  same.generation == state.generation and same.proxy.pid == state.proxy.pid and same.backend.pid == state.backend.pid
)
local root_after = assert(vim.uv.fs_lstat(paths.root))
local control_after = assert(vim.uv.fs_lstat(paths.control))
assert(
  root_before.dev == root_after.dev and root_before.ino == root_after.ino,
  "broker changed authority root identity"
)
assert(
  control_before.dev == control_after.dev and control_before.ino == control_after.ino,
  "broker changed control identity"
)
assert(lifecycle.set_test_procfs_authority(true))

-- A manager cut after running pending publication is reconciled through the
-- exact broker/control generation. It must not become permanent manual state.
local cut_generation = state.generation
local cut_proxy_pid, cut_backend_pid = state.proxy.pid, state.backend.pid
local cut_pending = vim.deepcopy(state)
cut_pending.phase = "running"
local exact_control_ino = cut_pending.broker.control_ino
cut_pending.broker.control_ino = exact_control_ino == "1" and "2" or "1"
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(cut_pending))
assert(lifecycle.write_launch_intent(broker_intent(state)))
assert(vim.uv.fs_unlink(paths.state))
lifecycle.release_lock()
local mismatched_pending = table.concat(vim.fn.readfile(paths.pending), "\n")
local mismatched_intent = table.concat(vim.fn.readfile(paths.launch), "\n")
local mismatched, mismatch_err = await(lifecycle.ensure_server)
assert(not mismatched and mismatch_err:find("control authority", 1, true), mismatch_err)
assert(table.concat(vim.fn.readfile(paths.pending), "\n") == mismatched_pending)
assert(table.concat(vim.fn.readfile(paths.launch), "\n") == mismatched_intent)
assert(not dead(cut_proxy_pid) and not dead(cut_backend_pid), "mismatched crash cut mutated broker roles")
cut_pending.broker.control_ino = exact_control_ino
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(cut_pending))
lifecycle.release_lock()
local reconciled, reconcile_err, reconciled_state = await(lifecycle.ensure_server)
assert(reconciled, reconcile_err)
assert(reconciled_state.generation ~= cut_generation, "running crash cut reused an unfinalized generation")
assert(dead(cut_proxy_pid) and dead(cut_backend_pid), "running crash cut left an old broker role alive")
state = reconciled_state

-- An incomplete schema-4 generation still has broker authority. Status must
-- report that recoverable-but-not-ready condition without acquiring a lock or
-- changing any durable authority bytes.
local pending = vim.deepcopy(state)
pending.phase = "running"
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(pending))
assert(vim.uv.fs_unlink(paths.state))
lifecycle.release_lock()
local pending_before = table.concat(vim.fn.readfile(paths.pending), "\n")
local control_before_pending = assert(vim.uv.fs_lstat(paths.control))
local incomplete_status, incomplete_state, incomplete_message = await(lifecycle.observe_server)
assert(
  incomplete_status == "unhealthy" and incomplete_state == nil and incomplete_message:find("running", 1, true),
  "schema-4 running pending state was not observed as unhealthy"
)
local entrypoint = vim.fs.joinpath(vim.fn.getcwd(), "lua", "mkchad", "opencode", "command.lua")
local command_result = await(function(done)
  vim.system({ vim.fn.exepath "nvim", "--headless", "-u", "NONE", "-l", entrypoint, "--", "status", "--json" }, done)
end)
assert(command_result.code == 0, command_result.stderr)
local command_status = vim.json.decode(command_result.stdout)
assert(
  command_status.status == "unhealthy"
    and command_status.state == vim.NIL
    and command_status.diagnostic.code == "broker_running_pending",
  "schema-4 broker diagnostic was not preserved by the standalone command"
)
assert(not vim.uv.fs_stat(paths.lock), "schema-4 status acquired a lifecycle lock")
assert(table.concat(vim.fn.readfile(paths.pending), "\n") == pending_before, "schema-4 status changed pending bytes")
local control_after_pending = assert(vim.uv.fs_lstat(paths.control))
assert(
  control_before_pending.dev == control_after_pending.dev and control_before_pending.ino == control_after_pending.ino,
  "schema-4 status changed control metadata"
)
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_state(state))
assert(lifecycle.remove_matching_pending_while_locked(state.generation))
lifecycle.release_lock()

-- U4 terminal cleanup is broker-owned: Lua sees only the matching receipt,
-- broker death, and the removed recorded control inode before it removes state.
assert(vim.uv.kill(state.backend.pid, "sigkill"))
assert(
  vim.wait(5000, function()
    return dead(state.backend.pid)
  end, 20),
  "recorded backend fixture PID survived cleanup"
)
local backend_dead_status, backend_dead_state, backend_dead_message = await(lifecycle.observe_server)
assert(
  backend_dead_status == "unhealthy" and backend_dead_state == nil and backend_dead_message,
  "broker-live/backend-dead generation was not observable as unhealthy"
)
local dead_backend_stop_notice
local original_notify = vim.notify
vim.notify = function(message)
  dead_backend_stop_notice = tostring(message)
end
lifecycle.stop_shared_server()
assert(
  vim.wait(10000, function()
    return dead_backend_stop_notice ~= nil
  end, 20),
  "broker stop after backend death timed out"
)
vim.notify = original_notify
assert(dead_backend_stop_notice:find("Stopped shared OpenCode broker and backend", 1, true), dead_backend_stop_notice)
assert(
  vim.wait(5000, function()
    return dead(state.backend.pid) and dead(state.proxy.pid)
  end, 20),
  "broker stop after backend death left a recorded role alive"
)
local recovered, recovered_err, recovered_state = await(lifecycle.ensure_server)
assert(recovered, recovered_err)
assert(
  recovered_state.generation ~= state.generation
    and recovered_state.proxy.pid ~= state.proxy.pid
    and recovered_state.backend.pid ~= state.backend.pid,
  "both-dead schema-4 recovery did not replace the exact generation"
)
assert(not vim.uv.fs_lstat(paths.control_quarantine), "schema-4 stale control quarantine was not conditionally removed")
local stop_notice
original_notify = vim.notify
vim.notify = function(message)
  stop_notice = tostring(message)
end
assert(lifecycle.set_test_procfs_authority(false))
lifecycle.stop_shared_server()
assert(
  vim.wait(10000, function()
    return stop_notice ~= nil
  end, 20),
  "schema-4 broker stop timed out"
)
vim.notify = original_notify
assert(lifecycle.set_test_procfs_authority(true))
assert(stop_notice:find("Stopped shared OpenCode broker and backend", 1, true), stop_notice)
assert(
  vim.wait(5000, function()
    return dead(recovered_state.backend.pid) and dead(recovered_state.proxy.pid)
  end, 20),
  "broker terminal receipt left a recorded role alive"
)
assert(lifecycle.read_state() == nil, "broker terminal receipt did not remove matching state")
assert(not vim.uv.fs_lstat(paths.control), "broker terminal receipt retained the control path")
vim.cmd "qa!"
