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
      pid = state.backend.pid,
      start_time = state.backend.start_time,
    },
  }
end

local fake = vim.fs.joinpath(paths.root, "opencode")
local fake_target = vim.fs.joinpath(paths.root, "opencode-real")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import os, signal, socket, sys, threading",
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
}, fake_target)
assert(vim.uv.fs_chmod(fake_target, 493))
assert(vim.uv.fs_symlink(fake_target, fake))
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
assert(state.backend.executable == fake_target, "broker did not freeze the canonical OpenCode executable")

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

local previous_generation = state.generation
local previous_proxy_pid, preserved_backend_pid = state.proxy.pid, state.backend.pid
vim.g.mkchad_opencode_test_fail_launch_write_after = 2
local failed_restart, failed_restart_err = await(lifecycle.restart_broker)
assert(not failed_restart and failed_restart_err:find("launch intent", 1, true), failed_restart_err)
local rollback_state = assert(lifecycle.read_state())
assert(
  rollback_state.generation == previous_generation and rollback_state.backend.pid == preserved_backend_pid,
  "failed broker restart did not restore complete authority"
)
assert(dead(previous_proxy_pid) and not dead(preserved_backend_pid), "failed broker restart changed the backend")
assert(not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.launch) and not vim.uv.fs_stat(paths.control))

vim.g.mkchad_opencode_test_fail_pending_remove = true
local failed_publication, failed_publication_err = await(lifecycle.restart_broker)
assert(not failed_publication and failed_publication_err:find("pending", 1, true), failed_publication_err)
rollback_state = assert(lifecycle.read_state())
assert(
  rollback_state.generation == previous_generation and rollback_state.backend.pid == preserved_backend_pid,
  "post-publication failure did not restore complete authority"
)
assert(not dead(preserved_backend_pid), "post-publication failure stopped the backend")
assert(not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.launch) and not vim.uv.fs_stat(paths.control))

vim.g.mkchad_opencode_test_fail_pending_write_after = 1
local failed_control_ready, failed_control_ready_err = await(lifecycle.restart_broker)
assert(not failed_control_ready and failed_control_ready_err:find("control-ready", 1, true), failed_control_ready_err)
rollback_state = assert(lifecycle.read_state())
assert(
  rollback_state.generation == previous_generation and rollback_state.backend.pid == preserved_backend_pid,
  "control-ready publication failure did not restore complete authority"
)
assert(not dead(preserved_backend_pid), "control-ready publication failure stopped the backend")
assert(not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.launch) and not vim.uv.fs_stat(paths.control))

local dead_launch_intent = broker_intent(rollback_state)
dead_launch_intent.backend.pid = nil
dead_launch_intent.backend.start_time = nil
local stale_socket = vim.system({
  assert(vim.fn.exepath "python3"),
  "-c",
  "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()",
  paths.control,
}):wait()
assert(stale_socket.code == 0, stale_socket.stderr)
assert(vim.uv.fs_chmod(paths.control, 384))
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_launch_intent(dead_launch_intent))
lifecycle.release_lock()
local reconciled_launch, reconciled_launch_err, reconciled_state = await(lifecycle.restart_broker)
assert(reconciled_launch, reconciled_launch_err)
assert(
  reconciled_state.generation ~= previous_generation and reconciled_state.backend.pid == preserved_backend_pid,
  "dead launch-intent reconciliation did not preserve the backend"
)
previous_generation = reconciled_state.generation

local entrypoint = vim.fs.joinpath(vim.fn.getcwd(), "lua", "mkchad", "opencode", "command.lua")
local restart_command = await(function(done)
  vim.system(
    { vim.fn.exepath "nvim", "--headless", "-u", "NONE", "-l", entrypoint, "--", "restart-broker", "--json" },
    { env = { MKCHAD_PERSISTENT_INSTANCE = "1" } },
    done
  )
end)
assert(restart_command.code == 0, restart_command.stderr .. restart_command.stdout)
local restart_result = vim.json.decode(restart_command.stdout)
assert(restart_result.ok and restart_result.status == "healthy", restart_command.stdout)
local restarted_state = assert(lifecycle.read_state())
assert(
  restarted_state.generation ~= previous_generation
    and restarted_state.proxy.pid ~= previous_proxy_pid
    and restarted_state.backend.pid == preserved_backend_pid,
  "broker restart did not preserve only the backend"
)
assert(dead(previous_proxy_pid) and not dead(preserved_backend_pid), "broker restart changed the wrong process")
state = restarted_state

local coexisting_generation = state.generation
local coexisting_backend_pid = state.backend.pid
local coexisting_pending = vim.deepcopy(state)
coexisting_pending.phase = "running"
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(coexisting_pending))
assert(lifecycle.write_launch_intent(broker_intent(state)))
lifecycle.release_lock()
local resumed, resume_err, resumed_state = await(lifecycle.restart_broker)
assert(resumed, resume_err)
assert(
  resumed_state.generation ~= coexisting_generation and resumed_state.backend.pid == coexisting_backend_pid,
  "restart could not recover coexisting complete and provisional authority"
)
state = resumed_state

local control_ready_generation = state.generation
local control_ready_backend_pid = state.backend.pid
local control_ready_pending = vim.deepcopy(state)
control_ready_pending.phase = "control-ready"
control_ready_pending.backend = nil
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(control_ready_pending))
assert(lifecycle.write_launch_intent(broker_intent(state)))
lifecycle.release_lock()
resumed, resume_err, resumed_state = await(lifecycle.restart_broker)
assert(resumed, resume_err)
assert(
  resumed_state.generation ~= control_ready_generation and resumed_state.backend.pid == control_ready_backend_pid,
  "restart could not recover control-ready provisional authority"
)
state = resumed_state

local occupied_public_port = state.port
local fallback_backend_pid = state.backend.pid
assert(vim.uv.kill(state.proxy.pid, "sigkill"))
assert(
  vim.wait(5000, function()
    return dead(state.proxy.pid)
  end, 20),
  "broker fixture did not stop before fallback restart"
)
assert(
  vim.wait(5000, function()
    return lifecycle.port_is_available(occupied_public_port)
  end, 20),
  "broker public port did not become reusable"
)
local occupied_public = assert(vim.uv.new_tcp())
assert(occupied_public:bind("127.0.0.1", occupied_public_port) == 0)
assert(occupied_public:listen(1, function() end) == 0)
local fallback, fallback_err, fallback_state = await(lifecycle.restart_broker)
occupied_public:close()
assert(fallback, fallback_err)
assert(
  fallback_state.port ~= occupied_public_port and fallback_state.backend.pid == fallback_backend_pid,
  "broker restart did not select a fallback around an unavailable old public port"
)
state = fallback_state

local state_less_control_generation = state.generation
local state_less_control_backend = state.backend.pid
local state_less_control = vim.deepcopy(state)
state_less_control.phase = "control-ready"
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(state_less_control))
assert(lifecycle.write_launch_intent(broker_intent(state)))
assert(vim.uv.fs_unlink(paths.state))
lifecycle.release_lock()
local recovered_control, recovered_control_err, recovered_control_state = await(lifecycle.restart_broker)
assert(recovered_control, recovered_control_err)
assert(
  recovered_control_state.generation ~= state_less_control_generation
    and recovered_control_state.backend.pid == state_less_control_backend,
  "state-less control-ready restart did not preserve the backend"
)
state = recovered_control_state

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
local mismatched, mismatch_err = await(lifecycle.restart_broker)
assert(not mismatched and mismatch_err:find("control authority", 1, true), mismatch_err)
assert(table.concat(vim.fn.readfile(paths.pending), "\n") == mismatched_pending)
assert(table.concat(vim.fn.readfile(paths.launch), "\n") == mismatched_intent)
assert(not dead(cut_proxy_pid) and not dead(cut_backend_pid), "mismatched crash cut mutated broker roles")
cut_pending.broker.control_ino = exact_control_ino
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_pending(cut_pending))
lifecycle.release_lock()
vim.g.mkchad_opencode_test_fail_pending_write_after = 2
local failed_pending_restart, failed_pending_restart_err = await(lifecycle.restart_broker)
assert(
  not failed_pending_restart and failed_pending_restart_err:find("running broker state", 1, true),
  failed_pending_restart_err
)
assert(not dead(cut_backend_pid), "failed running-pending restart stopped the backend")
assert(
  vim.deep_equal(lifecycle.read_pending(), cut_pending),
  "failed restart did not restore pending authority: " .. failed_pending_restart_err
)
assert(lifecycle.read_launch_intent().generation == cut_generation)
local reconciled, reconcile_err, reconciled_state = await(lifecycle.restart_broker)
assert(reconciled, reconcile_err)
assert(reconciled_state.generation ~= cut_generation, "running crash cut reused an unfinalized generation")
assert(dead(cut_proxy_pid) and not dead(cut_backend_pid), "running crash cut did not preserve only the backend")
assert(reconciled_state.backend.pid == cut_backend_pid, "running crash cut replaced the backend")
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
local incomplete_status, incomplete_state, incomplete_message, _, incomplete_projection =
  await(lifecycle.observe_server)
assert(
  incomplete_status == "unhealthy" and incomplete_state == nil and incomplete_message:find("running", 1, true),
  "schema-4 running pending state was not observed as unhealthy"
)
assert(
  incomplete_projection.persisted_state == "present"
    and incomplete_projection.persisted_version == pending.backend.local_version,
  "unhealthy lifecycle projection erased persisted backend evidence"
)
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
local command_persisted
for _, item in ipairs(command_status.inventory.observations) do
  if item.id == "opencode:persisted" then
    command_persisted = item
  end
end
assert(
  command_persisted
    and command_persisted.state == "present"
    and command_persisted.version == pending.backend.local_version,
  "unhealthy status inventory erased persisted backend evidence"
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
assert(lifecycle.set_test_procfs_authority(false))
local cleared, clear_err = await(lifecycle.clear_server)
assert(not cleared and clear_err:find("remains live", 1, true), clear_err)
assert(lifecycle.read_state(), "clear removed a live schema-4 generation")
local killed, kill_err = await(lifecycle.kill_server, 10000)
assert(lifecycle.set_test_procfs_authority(true))
assert(killed, kill_err)
assert(
  vim.wait(5000, function()
    return dead(recovered_state.backend.pid) and dead(recovered_state.proxy.pid)
  end, 20),
  "broker terminal receipt left a recorded role alive"
)
assert(lifecycle.read_state() == nil, "broker terminal receipt did not remove matching state")
assert(not vim.uv.fs_lstat(paths.control), "broker terminal receipt retained the control path")
assert(not vim.uv.fs_lstat(paths.tls), "schema-4 kill retained TLS material")
assert(not vim.uv.fs_lstat(paths.log), "schema-4 kill retained the backend log")
assert(not vim.uv.fs_lstat(paths.proxy_log), "schema-4 kill retained the broker log")

-- Kill also reconciles an exact stale control socket after both recorded roles
-- were terminated outside the managed lifecycle.
local crash_started, crash_err, crash_state = await(lifecycle.ensure_server)
assert(crash_started, crash_err)
assert(vim.uv.kill(crash_state.backend.pid, "sigkill"))
assert(vim.uv.kill(crash_state.proxy.pid, "sigkill"))
assert(
  vim.wait(5000, function()
    return dead(crash_state.backend.pid) and dead(crash_state.proxy.pid)
  end, 20),
  "crashed schema-4 roles did not terminate"
)
assert(vim.uv.fs_lstat(paths.control), "crashed broker did not leave its control socket fixture")
killed, kill_err = await(lifecycle.kill_server, 10000)
assert(killed, kill_err)
assert(lifecycle.read_state() == nil, "crashed schema-4 kill retained lifecycle state")
assert(not vim.uv.fs_lstat(paths.control), "crashed schema-4 kill retained the exact stale control socket")
assert(not vim.uv.fs_lstat(paths.tls), "crashed schema-4 kill retained TLS material")

local coexist_started, coexist_start_err, coexist_old_state = await(lifecycle.ensure_server)
assert(coexist_started, coexist_start_err)
local coexist_restarted, coexist_restart_err, coexist_pending = await(lifecycle.restart_broker)
assert(coexist_restarted, coexist_restart_err)
coexist_pending.phase = "running"
assert(await(lifecycle.acquire_lock))
assert(lifecycle.write_state(coexist_old_state))
assert(lifecycle.write_pending(coexist_pending))
assert(lifecycle.write_launch_intent(broker_intent(coexist_pending)))
lifecycle.release_lock()
assert(vim.uv.kill(coexist_pending.backend.pid, "sigkill"))
assert(vim.wait(5000, function()
  return dead(coexist_pending.backend.pid)
end, 20), "coexisting adopted backend did not terminate")
local dead_backend_restart, dead_backend_err = await(lifecycle.restart_broker)
assert(not dead_backend_restart and dead_backend_err:find("no longer running", 1, true), dead_backend_err)
assert(vim.wait(5000, function()
  return dead(coexist_pending.proxy.pid)
end, 20), "dead-backend reconciliation retained the adopted broker")
assert(
  not lifecycle.read_state() and not vim.uv.fs_lstat(paths.pending) and not vim.uv.fs_lstat(paths.launch),
  "dead-backend reconciliation retained lifecycle authority"
)

local slow_fake = vim.fn.readfile(fake_target)
table.insert(slow_fake, 4, "signal.signal(signal.SIGTERM, lambda *_: None)")
vim.fn.writefile(slow_fake, fake_target)
assert(vim.uv.fs_chmod(fake_target, 493))
local stopping_started, stopping_start_err, stopping_state = await(lifecycle.ensure_server)
assert(stopping_started, stopping_start_err)
local stop_finished, stop_ok, stop_err = false, nil, nil
lifecycle.stop_server(function(ok, err)
  stop_ok, stop_err, stop_finished = ok, err, true
end)
local stopping_status
local function poll_stopping()
  lifecycle.observe_server(function(status)
    if status == "stopping" then
      stopping_status = status
    elseif not stop_finished then
      vim.defer_fn(poll_stopping, 10)
    end
  end)
end
poll_stopping()
assert(
  vim.wait(5000, function()
    return stopping_status ~= nil
  end, 10),
  "broker stopping phase was not observable"
)
local stopping_command = await(function(done)
  vim.system({ vim.fn.exepath "nvim", "--headless", "-u", "NONE", "-l", entrypoint, "--", "status", "--json" }, done)
end)
local stopping_result = vim.json.decode(stopping_command.stdout)
assert(
  stopping_command.code == 0
    and stopping_result.status == "stopping"
    and stopping_result.inventory
    and #stopping_result.inventory.components == 14,
  stopping_command.stderr
)
assert(
  vim.wait(40000, function()
    return stop_finished
  end, 20),
  "broker stopping fixture did not terminate"
)
assert(stop_ok, stop_err)
assert(dead(stopping_state.backend.pid) and dead(stopping_state.proxy.pid), "broker stop retained a recorded role")
vim.cmd "qa!"
