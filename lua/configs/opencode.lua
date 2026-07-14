local uv = vim.uv
local host = "127.0.0.1"
local preferred_port = 4096
local startup_timeout_ms = 15000
local health_interval_ms = 200
local local_tui_bootstrap_ms = 200

local function notify(message, level)
  vim.notify(message, level, { title = "OpenCode" })
end

local function hostname()
  return ((uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_"))
end

local function paths()
  local root = vim.fs.joinpath(vim.fn.stdpath("state"), "opencode", hostname())
  return {
    root = root,
    state = vim.fs.joinpath(root, "state.json"),
    log = vim.fs.joinpath(root, "server.log"),
    lock = vim.fs.joinpath(root, "startup.lock"),
    lock_owner = vim.fs.joinpath(root, "startup.lock", "owner.json"),
  }
end

local function iso_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function random_token()
  return table.concat({ tostring(vim.fn.getpid()), tostring(uv.hrtime()), tostring(math.random(0, 0x7fffffff)) }, "-")
end

local function ensure_state_dir()
  local state_paths = paths()
  if vim.fn.mkdir(state_paths.root, "p", 448) == 0 and not uv.fs_stat(state_paths.root) then
    return nil, "Unable to create OpenCode state directory " .. state_paths.root
  end
  uv.fs_chmod(state_paths.root, 448)
  return state_paths
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local size = uv.fs_fstat(fd).size
  -- procfs reports zero-sized pseudo-files even when cmdline has content.
  if size == 0 then
    size = 8192
  end
  local data = uv.fs_read(fd, size, 0)
  uv.fs_close(fd)
  return data
end

local function read_state()
  local state_path = paths().state
  local content = read_file(state_path)
  if not content then
    return nil, "missing"
  end
  local ok, state = pcall(vim.json.decode, content)
  if not ok or type(state) ~= "table" then
    return nil, "malformed"
  end
  if state.schema ~= 1 then
    return nil, state.schema and "unsupported schema" or "malformed"
  end
  if state.hostname ~= hostname()
    or type(state.pid) ~= "number"
    or state.pid <= 0
    or type(state.generation) ~= "string"
    or type(state.port) ~= "number"
    or type(state.url) ~= "string"
  then
    return nil, "malformed"
  end
  return state, "valid"
end

local function write_private(path, content)
  local fd, err = uv.fs_open(path, "w", 384)
  if not fd then
    return nil, err
  end
  local ok, write_err = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  uv.fs_chmod(path, 384)
  if not ok then
    uv.fs_unlink(path)
    return nil, write_err
  end
  return true
end

local function write_state(state)
  local state_paths, err = ensure_state_dir()
  if not state_paths then
    return nil, err
  end
  local temporary = state_paths.state .. "." .. random_token() .. ".tmp"
  local ok, write_err = write_private(temporary, vim.json.encode(state))
  if not ok then
    return nil, "Unable to write OpenCode state: " .. (write_err or "unknown error")
  end
  local renamed, rename_err = uv.fs_rename(temporary, state_paths.state)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, "Unable to replace OpenCode state: " .. (rename_err or "unknown error")
  end
  uv.fs_chmod(state_paths.state, 384)
  return true
end

local function remove_matching_state(generation)
  local state = read_state()
  if state and state.generation == generation then
    uv.fs_unlink(paths().state)
  end
end

local function curl_quote(value)
  return value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
end

local function probe_health(url, callback)
  local started_at = uv.hrtime()
  local stdout, stderr = {}, {}
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "1",
    "--max-time",
    "2",
    "--config",
    "-",
    "--write-out",
    "\n%{http_code}",
    url .. "/global/health",
  }
  local job = vim.fn.jobstart(command, {
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local response = table.concat(stdout, "\n")
        local status = tonumber(response:match("\n(%d%d%d)%s*$"))
        local body = response:gsub("\n%d%d%d%s*$", "")
        local latency_ms = math.floor((uv.hrtime() - started_at) / 1000000)
        if status == 401 then
          callback(nil, { kind = "unauthorized", latency_ms = latency_ms })
          return
        end
        if code ~= 0 or not status or status < 200 or status >= 300 then
          local message = table.concat(stderr, " ")
          local kind = message:find("timed out", 1, true) and "timeout" or "unavailable"
          callback(nil, { kind = kind, latency_ms = latency_ms, status = status })
          return
        end
        local ok, health = pcall(vim.json.decode, body)
        if not ok or type(health) ~= "table" then
          callback(nil, { kind = "invalid JSON", latency_ms = latency_ms })
          return
        end
        if health.healthy ~= true then
          callback(nil, { kind = "unhealthy", latency_ms = latency_ms })
          return
        end
        callback(health, { kind = "healthy", latency_ms = latency_ms, status = status })
      end)
    end,
  })
  if job <= 0 then
    callback(nil, { kind = "unable to launch curl", latency_ms = 0 })
    return
  end
  local config = 'header = "Accept: application/json"\n'
  if vim.env.OPENCODE_SERVER_PASSWORD and vim.env.OPENCODE_SERVER_PASSWORD ~= "" then
    config = config
      .. 'user = "'
      .. curl_quote((vim.env.OPENCODE_SERVER_USERNAME or "opencode") .. ":" .. vim.env.OPENCODE_SERVER_PASSWORD)
      .. '"\n'
  end
  vim.fn.chansend(job, config)
  vim.fn.chanclose(job, "stdin")
end

-- Keep reload credentials and payloads on curl's stdin, as with health probes.
-- The directory header deliberately matches the attached TUI's current cwd.
local function request_json(url, path, method, body, directory, callback)
  local stdout = {}
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "1",
    "--max-time",
    "4",
    "--config",
    "-",
    "--write-out",
    "\n%{http_code}",
    "-X",
    method,
    url .. path,
  }
  local job = vim.fn.jobstart(command, {
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local response = table.concat(stdout, "\n")
        local status = tonumber(response:match("\n(%d%d%d)%s*$"))
        local response_body = response:gsub("\n%d%d%d%s*$", "")
        if status == 401 then
          callback(nil, { kind = "unauthorized", status = status })
        elseif code ~= 0 or not status or status < 200 or status >= 300 then
          callback(nil, { kind = "HTTP " .. (status or "request failure"), status = status })
        elseif response_body == "" then
          callback({}, { kind = "ok", status = status })
        else
          local ok, decoded = pcall(vim.json.decode, response_body)
          callback(ok and decoded or nil, { kind = ok and "ok" or "invalid JSON", status = status })
        end
      end)
    end,
  })
  if job <= 0 then
    callback(nil, { kind = "unable to launch curl" })
    return
  end
  local config = {
    'header = "Accept: application/json"',
    'header = "Content-Type: application/json"',
  }
  if directory and directory ~= "" then
    table.insert(config, 'header = "x-opencode-directory: ' .. curl_quote(directory) .. '"')
  end
  if vim.env.OPENCODE_SERVER_PASSWORD and vim.env.OPENCODE_SERVER_PASSWORD ~= "" then
    table.insert(config, 'user = "' .. curl_quote((vim.env.OPENCODE_SERVER_USERNAME or "opencode") .. ":" .. vim.env.OPENCODE_SERVER_PASSWORD) .. '"')
  end
  if body then
    table.insert(config, 'data-binary = "' .. curl_quote(vim.json.encode(body)) .. '"')
  end
  vim.fn.chansend(job, table.concat(config, "\n") .. "\n")
  vim.fn.chanclose(job, "stdin")
end

local function port_is_available(port)
  local tcp = uv.new_tcp()
  if not tcp then
    return false
  end
  local ok = tcp:bind(host, port)
  if ok == 0 then
    -- libuv can bind an already-listened-to port on some platforms until a
    -- listener is actually created. Probe the complete operation so automatic
    -- selection never mistakes an occupied endpoint for an available one.
    ok = tcp:listen(1, function() end)
  end
  tcp:close()
  return ok == 0
end

local function explicit_port()
  local value = vim.env.OPENCODE_PORT
  if not value or value == "" then
    return nil
  end
  if not value:match("^%d+$") then
    return nil, "OPENCODE_PORT must be an integer from 1 through 65535"
  end
  local port = tonumber(value)
  if not port or port < 1 or port > 65535 then
    return nil, "OPENCODE_PORT must be an integer from 1 through 65535"
  end
  return port
end

local function pid_is_live(pid)
  if not uv.fs_stat("/proc/" .. pid) then
    return false
  end
  local stat = read_file("/proc/" .. pid .. "/stat")
  local state = stat and stat:match("%)%s+(%a)")
  return state ~= "Z"
end

local function proc_cmdline(pid)
  local command = read_file("/proc/" .. pid .. "/cmdline")
  if not command or command == "" then
    return nil
  end
  local argv = vim.split(command, "\0", { plain = true, trimempty = true })
  return #argv > 0 and argv or nil
end

local function proc_executable(pid)
  return uv.fs_readlink("/proc/" .. pid .. "/exe")
end

local function argv_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index, value in ipairs(left) do
    if value ~= right[index] then
      return false
    end
  end
  return true
end

local function process_listens_on_port(pid, port)
  local wanted_port = string.format("%04X", port)
  local tcp = read_file("/proc/net/tcp")
  if not tcp then
    return false
  end
  local inode
  for line in tcp:gmatch("[^\n]+") do
    local fields = vim.split(line, "%s+", { trimempty = true })
    local address, listening = fields[2], fields[4] == "0A"
    if address and listening and address:match("^[0-9A-Fa-f]+:" .. wanted_port .. "$") then
      inode = fields[10]
      break
    end
  end
  if not inode then
    return false
  end
  for _, fd in ipairs(vim.fn.glob("/proc/" .. pid .. "/fd/*", true, true)) do
    if uv.fs_readlink(fd) == "socket:[" .. inode .. "]" then
      return true
    end
  end
  return false
end

local function process_is_owned(state)
  if not state or state.hostname ~= hostname() or type(state.pid) ~= "number" or state.pid <= 0 then
    return false, "invalid managed PID"
  end
  if not pid_is_live(state.pid) then
    return false, "PID is not live"
  end
  if type(state.process_executable) ~= "string" or type(state.argv) ~= "table" then
    return false, "managed process identity is unavailable"
  end
  local executable = proc_executable(state.pid)
  local argv = proc_cmdline(state.pid)
  if executable ~= state.process_executable or not argv_equal(argv, state.argv) then
    return false, "PID executable or argv does not match the managed opencode serve process"
  end
  if #state.argv < 6
    or state.argv[#state.argv - 4] ~= "serve"
    or state.argv[#state.argv - 3] ~= "--hostname"
    or state.argv[#state.argv - 2] ~= host
    or state.argv[#state.argv - 1] ~= "--port"
    or state.argv[#state.argv] ~= tostring(state.port)
  then
    return false, "managed process argv is not an exact opencode serve command"
  end
  return true, "verified"
end

local function signal_managed(state, signal)
  local owned, reason = process_is_owned(state)
  if not owned then
    return nil, reason
  end
  local ok, err = uv.kill(state.pid, signal)
  if not ok then
    return nil, err or "unable to signal managed process"
  end
  return true
end

local function terminate_generation(state, deadline_ns, callback)
  local owned, reason = process_is_owned(state)
  if not owned then
    callback(not pid_is_live(state.pid), reason)
    return
  end
  local sent, signal_err = signal_managed(state, "sigterm")
  if not sent then
    callback(false, signal_err)
    return
  end
  local escalated = false
  local function wait_for_exit()
    if not pid_is_live(state.pid) then
      callback(true)
      return
    end
    if uv.hrtime() >= deadline_ns then
      if not escalated then
        local killed, kill_err = signal_managed(state, "sigkill")
        if not killed then
          callback(false, kill_err)
          return
        end
        escalated = true
        vim.defer_fn(wait_for_exit, health_interval_ms)
        return
      else
        callback(false, "managed process did not exit after SIGKILL")
        return
      end
    end
    vim.defer_fn(wait_for_exit, health_interval_ms)
  end
  wait_for_exit()
end

local lock_token
local function read_lock_owner()
  local owner_content = read_file(paths().lock_owner)
  if not owner_content then
    return nil
  end
  local ok, owner = pcall(vim.json.decode, owner_content)
  return ok and type(owner) == "table" and owner or nil
end

local function lock_is_owned()
  local owner = read_lock_owner()
  return owner
    and owner.token == lock_token
    and owner.pid == vim.fn.getpid()
    and owner.hostname == hostname()
    and type(owner.deadline_ns) == "number"
    and uv.hrtime() < owner.deadline_ns
end

local function release_lock()
  if lock_token and lock_is_owned() then
    -- Atomically detach the exact lock directory we validated. This cannot
    -- unlink a newly acquired startup.lock after an expiry/reclaim race.
    local released = paths().lock .. ".release-" .. lock_token
    if uv.fs_rename(paths().lock, released) then
      local content = read_file(vim.fs.joinpath(released, "owner.json"))
      local ok, owner = false, nil
      if content then
        ok, owner = pcall(vim.json.decode, content)
      end
      if ok and owner and owner.token == lock_token and owner.pid == vim.fn.getpid() and owner.hostname == hostname() then
        uv.fs_unlink(vim.fs.joinpath(released, "owner.json"))
        uv.fs_rmdir(released)
      else
        -- Preserve an unexpected owner record for diagnosis rather than
        -- removing it. A future bounded stale-lock reclaim can handle it.
        uv.fs_rename(released, paths().lock)
      end
    end
  end
  lock_token = nil
end

local function lock_is_stale()
  local lock_stat = uv.fs_stat(paths().lock)
  local owner = read_lock_owner()
  -- A contender can observe the directory between mkdir and atomic owner
  -- publication. It is not stale merely because metadata is briefly absent.
  if not owner or owner.hostname ~= hostname() or type(owner.pid) ~= "number" or type(owner.token) ~= "string" then
    local created_ns = lock_stat and lock_stat.mtime and lock_stat.mtime.sec * 1000000000 + (lock_stat.mtime.nsec or 0)
    return created_ns and uv.hrtime() >= created_ns + startup_timeout_ms * 1000000 or false
  end
  if type(owner.deadline_ns) ~= "number" or uv.hrtime() >= owner.deadline_ns then
    return true
  end
  return not pid_is_live(owner.pid)
end

local function reclaim_stale_lock()
  local owner = read_lock_owner()
  if owner and not lock_is_stale() then
    return false
  end
  if not owner and not lock_is_stale() then
    return false
  end
  -- Rename isolates exactly the directory that was checked. A new acquirer can
  -- create startup.lock after this rename without being removed by this cleanup.
  local tombstone = paths().lock .. ".stale-" .. random_token()
  if not uv.fs_rename(paths().lock, tombstone) then
    return false
  end
  local moved_owner = read_file(vim.fs.joinpath(tombstone, "owner.json"))
  if moved_owner then
    local ok, decoded = pcall(vim.json.decode, moved_owner)
    if ok and owner and decoded.token ~= owner.token then
      -- This should be impossible after the atomic rename. Preserve evidence
      -- rather than deleting an owner we did not validate.
      uv.fs_rename(tombstone, paths().lock)
      return false
    end
  end
  uv.fs_unlink(vim.fs.joinpath(tombstone, "owner.json"))
  uv.fs_rmdir(tombstone)
  return true
end

local function acquire_lock(callback, retried, deadline_ns)
  local state_paths, err = ensure_state_dir()
  if not state_paths then
    callback(false, err)
    return
  end
  local token = random_token()
  if uv.fs_mkdir(state_paths.lock, 448) then
    lock_token = token
    local owner = {
      token = token,
      pid = vim.fn.getpid(),
      hostname = hostname(),
      acquired_at_ns = uv.hrtime(),
      deadline_ns = deadline_ns or uv.hrtime() + startup_timeout_ms * 1000000,
    }
    local wrote, write_err = write_private(state_paths.lock_owner, vim.json.encode(owner))
    if not wrote then
      release_lock()
      callback(false, "Unable to write OpenCode startup lock: " .. (write_err or "unknown error"))
      return
    end
    if not lock_is_owned() then
      release_lock()
      callback(false, "OpenCode startup lock ownership was lost before startup")
      return
    end
    callback(true)
    return
  end
  if not retried and reclaim_stale_lock() then
    acquire_lock(callback, true, deadline_ns)
    return
  end
  callback(false, "OpenCode startup is already in progress")
end

local function wait_for_health(url, deadline_ns, callback)
  probe_health(url, function(health, detail)
    if health then
      callback(health, detail)
    elseif uv.hrtime() >= deadline_ns then
      callback(nil, detail)
    else
      vim.defer_fn(function()
        wait_for_health(url, deadline_ns, callback)
      end, health_interval_ms)
    end
  end)
end

local function resolve_executable()
  local executable = vim.fn.exepath("opencode")
  if executable == "" then
    return nil, nil, "Unable to find opencode on PATH"
  end
  local output = vim.fn.systemlist({ executable, "--version" })
  local version = vim.v.shell_error == 0 and output[1] or "unknown"
  return executable, version
end

local function select_port(state, excluded_ports)
  local function available(port)
    return not (excluded_ports and excluded_ports[port]) and port_is_available(port)
  end
  local requested, request_err = explicit_port()
  if request_err then
    return nil, nil, request_err
  end
  if requested then
    if not port_is_available(requested) then
      return nil, nil, "Explicit OPENCODE_PORT " .. requested .. " is occupied by an unknown or incompatible service"
    end
    return requested, "explicit"
  end
  if state and available(state.port) then
    return state.port, "persisted"
  end
  if available(preferred_port) then
    return preferred_port, "preferred 4096"
  end
  for _ = 1, 20 do
    local candidate = math.random(49152, 65535)
    if available(candidate) then
      return candidate, "fallback"
    end
  end
  return nil, nil, "Unable to find an available OpenCode port"
end

local function spawn_server(state, deadline_ns, callback, excluded_ports)
  local state_paths = paths()
  local executable, version, executable_err = resolve_executable()
  if not executable then
    callback(nil, executable_err)
    return
  end
  local log_fd, log_err = uv.fs_open(state_paths.log, "a", 384)
  local stdin_fd = uv.fs_open("/dev/null", "r", 0)
  if not log_fd or not stdin_fd then
    if log_fd then
      uv.fs_close(log_fd)
    end
    if stdin_fd then
      uv.fs_close(stdin_fd)
    end
    callback(nil, "Unable to open OpenCode server log " .. state_paths.log .. ": " .. (log_err or "unknown error"))
    return
  end
  uv.fs_chmod(state_paths.log, 384)
  local port, source, port_err = select_port(state, excluded_ports)
  if not port then
    uv.fs_close(stdin_fd)
    uv.fs_close(log_fd)
    callback(nil, port_err .. "; see " .. state_paths.log)
    return
  end
  local generation = random_token()
  local handle, pid = uv.spawn(executable, {
    args = { "serve", "--hostname", host, "--port", tostring(port) },
    cwd = vim.env.HOME or vim.fn.expand("~"),
    detached = true,
    stdio = { stdin_fd, log_fd, log_fd },
  }, function() end)
  uv.fs_close(stdin_fd)
  uv.fs_close(log_fd)
  if not handle or not pid then
    callback(nil, "Unable to launch OpenCode server; see " .. state_paths.log)
    return
  end
  handle:unref()
  handle:close()
  -- Wait one event-loop turn so procfs observes the exec rather than the
  -- short-lived launcher. State records the complete observed identity, never
  -- a substring match that a reused PID can satisfy.
  vim.defer_fn(function()
    local managed = {
      schema = 1,
      hostname = hostname(),
      pid = pid,
      generation = generation,
      host = host,
      port = port,
      url = ("http://%s:%d"):format(host, port),
      port_source = source,
      started_at = iso_now(),
      cwd = vim.env.HOME or vim.fn.expand("~"),
      log = state_paths.log,
      executable = executable,
      local_version = version,
      process_executable = proc_executable(pid),
      argv = proc_cmdline(pid),
    }
    local owned, ownership = process_is_owned(managed)
    if not owned then
      callback(nil, "OpenCode child exited or did not exec the expected command (" .. ownership .. "); see " .. state_paths.log, port)
      return
    end
    local wrote, write_err = write_state(managed)
    if not wrote then
      terminate_generation(managed, deadline_ns, function(cleaned, cleanup_err)
        local suffix = cleaned and "" or "; cleanup failed: " .. (cleanup_err or "unknown error")
        callback(nil, write_err .. suffix, port)
      end)
      return
    end
    wait_for_health(managed.url, deadline_ns, function(health, detail)
      local still_owned, ownership_reason = process_is_owned(managed)
      if health and still_owned and process_listens_on_port(managed.pid, managed.port) then
        managed.server_version = health.version
        write_state(managed)
        callback(managed)
        return
      end
      local failure = health and "unexpected endpoint process" or detail.kind
      terminate_generation(managed, deadline_ns, function(cleaned, cleanup_err)
        if cleaned then
          remove_matching_state(generation)
        else
          managed.cleanup_error = cleanup_err or "failed cleanup after readiness failure"
          write_state(managed)
        end
        local ownership_suffix = still_owned and "" or "; child identity lost: " .. ownership_reason
        local cleanup_suffix = cleaned and "" or "; cleanup failed: " .. (cleanup_err or "unknown error")
        callback(
          nil,
          "OpenCode did not become healthy at "
            .. managed.url
            .. " ("
            .. failure
            .. ")"
            .. ownership_suffix
            .. cleanup_suffix
            .. "; see "
            .. state_paths.log,
          port
        )
      end)
    end)
  end, 10)
end

local ensure_waiters = {}
local ensure_active = false
local local_tui

local function finish_ensure(ok, err, state)
  local callbacks = ensure_waiters
  ensure_waiters = {}
  ensure_active = false
  for _, callback in ipairs(callbacks) do
    callback(ok, err, state)
  end
end

local function tui_valid()
  if not local_tui or not local_tui.term or not local_tui.term:valid() then
    return false
  end
  local job = local_tui.job
  if type(job) ~= "number" or job <= 0 then
    return false
  end
  return vim.fn.jobwait({ job }, 0)[1] == -1
end

local function close_local_tui()
  if tui_valid() then
    local_tui.term:close()
  end
  local_tui = nil
end

local terminal_position = "default"
local terminal_sizes = {
  bottom = { height = 0.35 },
  top = { height = 0.35 },
  left = { width = 0.35 },
  right = { width = 0.35 },
  float = { height = 0.9, width = 0.9 },
}
local terminal_positions = vim.tbl_keys(terminal_sizes)
table.insert(terminal_positions, "default")
table.sort(terminal_positions)

local function terminal_opts(position)
  position = position or terminal_position
  if position == "default" then
    position = vim.o.columns >= vim.o.lines and "bottom" or "right"
  end
  return {
    win = vim.tbl_deep_extend("force", { position = position, enter = false }, terminal_sizes[position] or {}),
  }
end

local function ensure_local_tui(state, callback)
  local cwd = vim.fn.getcwd()
  if cwd == "" then
    callback(false, "Unable to determine the current Neovim directory")
    return
  end
  if tui_valid()
    and local_tui.url == state.url
    and local_tui.directory == cwd
    and local_tui.generation == state.generation
  then
    callback(true)
    return
  end
  close_local_tui()
  local command = { "opencode", "attach", state.url, "--dir", cwd }
  local term, created = require("snacks.terminal").get(command, vim.tbl_deep_extend("force", terminal_opts(), { create = true }))
  if not term then
    callback(false, "Unable to create the local OpenCode attached TUI")
    return
  end
  local buffer = term.buf or term.bufnr
  local job = term.job or term.job_id
  if (not job or job <= 0) and buffer and vim.api.nvim_buf_is_valid(buffer) then
    job = vim.b[buffer].terminal_job_id
  end
  if type(job) ~= "number" or job <= 0 then
    callback(false, "OpenCode attached TUI did not expose a live terminal job")
    return
  end
  local_tui = {
    term = term,
    job = job,
    url = state.url,
    directory = cwd,
    generation = state.generation,
    command = command,
  }
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buffer,
      once = true,
      callback = function()
        -- TermClose status is not a liveness signal: SIGKILL and normal exit
        -- are both dead local TUIs and must be recreated on the next operation.
        if local_tui and local_tui.term == term then
          local_tui = nil
        end
      end,
    })
  end
  if created then
    vim.defer_fn(function()
      callback(true)
    end, local_tui_bootstrap_ms)
  else
    callback(true)
  end
end

local function managed_state_if_healthy(state, requested, callback)
  if not state then
    callback(nil, { kind = "missing" })
    return
  end
  probe_health(state.url, function(health, detail)
    local owned, ownership = process_is_owned(state)
    if detail.kind == "unauthorized" then
      callback(nil, detail)
    elseif health then
      if requested and state.port ~= requested then
        callback(nil, {
          kind = "explicit-port-conflict",
          message = "A managed OpenCode server uses " .. state.url .. "; stop the shared server before changing OPENCODE_PORT",
        })
      elseif not owned then
        callback(nil, { kind = "unmanaged-endpoint", message = ownership })
      elseif not process_listens_on_port(state.pid, state.port) then
        callback(nil, {
          kind = "unmanaged-endpoint",
          message = "managed PID does not own the listening socket for " .. state.url,
        })
      else
        callback(state, detail)
      end
    elseif owned then
      callback(nil, { kind = "owned-unhealthy", message = detail.kind })
    elseif pid_is_live(state.pid) then
      callback(nil, { kind = "unverifiable-pid", message = ownership })
    else
      callback(nil, { kind = "stale", message = detail.kind })
    end
  end)
end

local function ensure_backend(callback)
  table.insert(ensure_waiters, callback)
  if ensure_active then
    return
  end
  ensure_active = true
  local deadline_ns = uv.hrtime() + startup_timeout_ms * 1000000
  local state = read_state()
  local requested, request_err = explicit_port()
  if request_err then
    finish_ensure(false, request_err)
    return
  end
  local function detail_error(detail, endpoint_state)
    if detail.kind == "unauthorized" then
      return "OpenCode authentication failed at " .. (endpoint_state and endpoint_state.url or "the managed endpoint") .. " (HTTP 401)"
    elseif detail.kind == "explicit-port-conflict" then
      return detail.message
    elseif detail.kind == "unmanaged-endpoint" then
      return "Refusing to adopt a healthy unmanaged OpenCode endpoint: " .. (detail.message or "ownership mismatch")
    elseif detail.kind == "unverifiable-pid" then
      return "Refusing to replace a live unverifiable managed PID: " .. (detail.message or "ownership mismatch")
    end
  end
  local function start_while_locked(attempt)
    if not lock_is_owned() then
      finish_ensure(false, "OpenCode startup lock ownership was lost before the critical section")
      return
    end
    local locked_state = read_state()
    managed_state_if_healthy(locked_state, requested, function(rechecked, detail)
      if rechecked then
        release_lock()
        ensure_local_tui(rechecked, function(ok, err)
          finish_ensure(ok, err, rechecked)
        end)
        return
      end
      local hard_error = detail_error(detail, locked_state)
      if hard_error then
        release_lock()
        finish_ensure(false, hard_error)
        return
      end
      local function launch()
        if not lock_is_owned() then
          finish_ensure(false, "OpenCode startup lock ownership was lost before launch")
          return
        end
        spawn_server(locked_state, deadline_ns, function(started, start_err, failed_port)
          if not started and not requested and attempt < 2 and uv.hrtime() < deadline_ns then
            -- A bind race may only retry through automatic port selection.
            if not lock_is_owned() then
              finish_ensure(false, "OpenCode startup lock ownership was lost before automatic retry")
              return
            end
            local excluded_ports = failed_port and { [failed_port] = true } or nil
            spawn_server(nil, deadline_ns, function(retried, retry_err)
              release_lock()
              if not retried then
                finish_ensure(false, retry_err)
                return
              end
              ensure_local_tui(retried, function(ok, err)
                finish_ensure(ok, err, retried)
              end)
            end, excluded_ports)
            return
          end
          release_lock()
          if not started then
            finish_ensure(false, start_err)
            return
          end
          ensure_local_tui(started, function(ok, err)
            finish_ensure(ok, err, started)
          end)
        end)
      end
      if detail.kind == "owned-unhealthy" then
        terminate_generation(locked_state, deadline_ns, function(cleaned, cleanup_err)
          if not cleaned then
            release_lock()
            finish_ensure(false, "Managed OpenCode process is unhealthy and cleanup failed: " .. (cleanup_err or "unknown error"))
            return
          end
          remove_matching_state(locked_state.generation)
          launch()
        end)
      else
        if detail.kind == "stale" and locked_state then
          remove_matching_state(locked_state.generation)
        end
        launch()
      end
    end)
  end
  managed_state_if_healthy(state, requested, function(healthy_state, detail)
    if healthy_state then
      ensure_local_tui(healthy_state, function(ok, err)
        finish_ensure(ok, err, healthy_state)
      end)
      return
    end
    local hard_error = detail_error(detail, state)
    if hard_error then
      finish_ensure(false, hard_error)
      return
    end
    acquire_lock(function(locked, lock_err)
      if not locked then
        local function wait_for_winner()
          local waiting_state = read_state()
          managed_state_if_healthy(waiting_state, requested, function(winner, winner_detail)
            if winner then
              ensure_local_tui(winner, function(ok, err)
                finish_ensure(ok, err, winner)
              end)
              return
            end
            local winner_error = detail_error(winner_detail, waiting_state)
            if winner_error then
              finish_ensure(false, winner_error)
            elseif uv.hrtime() >= deadline_ns then
              acquire_lock(function(relocked, retry_err)
                if relocked then
                  start_while_locked(1)
                else
                  finish_ensure(false, retry_err or lock_err)
                end
              end, true, deadline_ns)
            else
              vim.defer_fn(wait_for_winner, health_interval_ms)
            end
          end)
        end
        wait_for_winner()
        return
      end
      start_while_locked(1)
    end, nil, deadline_ns)
  end)
end

local function show_local_tui(toggle)
  ensure_backend(function(ok, err)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    if toggle then
      local_tui.term:toggle()
    else
      local_tui.term:show()
    end
  end)
end

local function stop_shared_server()
  acquire_lock(function(locked, lock_err)
    if not locked then
      notify(lock_err, vim.log.levels.ERROR)
      return
    end
    local state, state_status = read_state()
    if not state then
      release_lock()
      close_local_tui()
      notify("No managed shared OpenCode server is active (state " .. state_status .. ")", vim.log.levels.INFO)
      return
    end
    local owned, ownership = process_is_owned(state)
    if not owned then
      release_lock()
      if ownership == "PID is not live" then
        remove_matching_state(state.generation)
        close_local_tui()
        notify("Removed stale state for an already stopped shared OpenCode server", vim.log.levels.INFO)
        return
      end
      notify("Refusing to stop shared OpenCode server: " .. ownership, vim.log.levels.ERROR)
      return
    end
    local sent, signal_err = signal_managed(state, "sigterm")
    if not sent then
      release_lock()
      notify("Refusing to stop shared OpenCode server: " .. signal_err, vim.log.levels.ERROR)
      return
    end
    local remaining = 25
    local escalated = false
    local function wait_for_stop()
      probe_health(state.url, function(health)
        if not health and not pid_is_live(state.pid) then
          remove_matching_state(state.generation)
          release_lock()
          close_local_tui()
          notify("Stopped shared OpenCode server", vim.log.levels.INFO)
        elseif remaining <= 0 and not escalated then
          local killed, kill_err = signal_managed(state, "sigkill")
          if killed then
            escalated = true
            remaining = 25
            vim.defer_fn(wait_for_stop, health_interval_ms)
          else
            release_lock()
            notify("Refusing to escalate an unverifiable shared OpenCode PID: " .. kill_err, vim.log.levels.ERROR)
          end
        elseif remaining <= 0 then
          release_lock()
          notify("Timed out stopping shared OpenCode server at " .. state.url, vim.log.levels.ERROR)
        else
          remaining = remaining - 1
          vim.defer_fn(wait_for_stop, health_interval_ms)
        end
      end)
    end
    wait_for_stop()
  end)
end

local reload_waiters = {}
local reload_active = false

local function absolute_cwd()
  local cwd = vim.fn.getcwd()
  if cwd == "" then
    return nil
  end
  local absolute = vim.fn.fnamemodify(cwd, ":p")
  return absolute == "/" and absolute or absolute:gsub("/$", "")
end

local function contains_busy_status(value)
  if type(value) == "string" then
    return value == "busy"
  elseif type(value) == "table" then
    for _, child in pairs(value) do
      if contains_busy_status(child) then
        return true
      end
    end
  end
  return false
end

local function contains_pending_item(value)
  if type(value) ~= "table" then
    return value ~= nil and value ~= false
  end
  if #value > 0 then
    return true
  end
  for _, child in pairs(value) do
    if contains_pending_item(child) then
      return true
    end
  end
  return false
end

local function finish_reload(ok, message)
  local callbacks = reload_waiters
  reload_waiters = {}
  reload_active = false
  for _, callback in ipairs(callbacks) do
    callback(ok, message)
  end
end

local function reload_current_directory(callback)
  table.insert(reload_waiters, callback or function() end)
  if reload_active then
    return
  end
  reload_active = true

  local directory = absolute_cwd()
  if not directory then
    finish_reload(false, "Unable to determine the current Neovim directory for OpenCode reload")
    return
  end
  local initial_state = read_state()
  managed_state_if_healthy(initial_state, nil, function(healthy_state, detail)
    if not healthy_state then
      finish_reload(
        false,
        "OpenCode reload is inactive for " .. directory .. " (" .. (detail and detail.kind or "inactive") .. "); it did not start a server"
      )
      return
    end
    acquire_lock(function(locked, lock_err)
      if not locked then
        finish_reload(false, "OpenCode reload could not acquire the lifecycle lock: " .. (lock_err or "unknown error"))
        return
      end
      local function fail(phase, err)
        release_lock()
        finish_reload(
          false,
          "OpenCode reload failed during " .. phase .. " for " .. directory .. ": " .. (err or "unknown error")
        )
      end
      local function request(path, method, body, done)
        request_json(healthy_state.url, path, method, body, directory, function(result, request_detail)
          if result then
            done(result)
          else
            done(nil, request_detail.kind)
          end
        end)
      end
      local locked_state = read_state()
      managed_state_if_healthy(locked_state, nil, function(rechecked, recheck_detail)
        if not rechecked then
          fail("managed-state validation", recheck_detail and recheck_detail.kind)
          return
        end
        if rechecked.pid ~= healthy_state.pid or rechecked.generation ~= healthy_state.generation or rechecked.url ~= healthy_state.url then
          fail("managed-state validation", "the shared server changed while reload was waiting")
          return
        end
        request("/session/status", "GET", nil, function(status, status_err)
          if not status then
            fail("session-status preflight", status_err)
          elseif contains_busy_status(status) then
            fail("session-status preflight", "current-directory work is active; reload was not attempted")
          else
            request("/permission", "GET", nil, function(permissions, permission_err)
              if not permissions then
                fail("permission preflight", permission_err)
              elseif contains_pending_item(permissions) then
                fail("permission preflight", "a current-directory permission is pending; reload was not attempted")
              else
                request("/question", "GET", nil, function(questions, question_err)
                  if not questions then
                    fail("question preflight", question_err)
                  elseif contains_pending_item(questions) then
                    fail("question preflight", "a current-directory question is pending; reload was not attempted")
                  else
                    request("/instance/dispose", "POST", nil, function(_, dispose_err)
                      if dispose_err then
                        fail("instance disposal", dispose_err)
                        return
                      end
                      local connected = require("opencode.server").connected
                      if connected then
                        connected:disconnect()
                      end
                      close_local_tui()
                      request("/path", "GET", nil, function(path, path_err)
                        if not path then
                          fail("instance recreation", path_err)
                        elseif path.directory ~= directory then
                          fail(
                            "routed-path validation",
                            "server returned " .. vim.inspect(path.directory) .. " instead of " .. directory
                          )
                        else
                          ensure_local_tui(rechecked, function(tui_ok, tui_err)
                            if not tui_ok then
                              fail("local TUI recreation", tui_err)
                              return
                            end
                            local loaded, discovery = pcall(require, "opencode.server.discovery")
                            if not loaded then
                              fail("plugin reconnection", discovery)
                              return
                            end
                            discovery.get():next(function()
                              local final_state = read_state()
                              if not final_state
                                or final_state.pid ~= rechecked.pid
                                or final_state.generation ~= rechecked.generation
                                or final_state.url ~= rechecked.url
                                or final_state.port ~= rechecked.port
                              then
                                fail("shared-server validation", "shared server state changed during reload")
                                return
                              end
                              release_lock()
                              finish_reload(
                                true,
                                "Reloaded OpenCode instance for "
                                  .. directory
                                  .. "; global process-cached configuration may still require shared stop/start"
                              )
                            end):catch(function(err)
                              fail("plugin reconnection", tostring(err))
                            end)
                          end)
                        end
                      end)
                    end)
                  end
                end)
              end
            end)
          end
        end)
      end)
    end)
  end)
end

local function show_info()
  local state, state_status = read_state()
  local configured, configured_err = explicit_port()
  local url = configured and ("http://%s:%d"):format(host, configured) or (state and state.url)
  local executable, local_version = resolve_executable()
  local lines = {
    "State directory: " .. paths().root,
    "State status: " .. state_status,
    "URL: " .. (url or "inactive"),
    "Port source: " .. (configured and "explicit environment" or (state and state.port_source or "preferred 4096 on first use")),
    "Local version: " .. (executable and local_version or "unavailable"),
    "Neovim cwd: " .. vim.fn.getcwd(),
    "Plugin SSE: " .. (require("opencode.server").connected and "connected" or "disconnected"),
    "Local TUI: "
      .. (tui_valid()
          and ("valid; " .. local_tui.url .. "; " .. local_tui.directory .. "; generation " .. local_tui.generation)
        or "absent"),
    "TUI API presence: unknown/unsupported",
    "Log path: " .. (state and state.log or paths().log),
  }
  if configured_err then
    table.insert(lines, "Port error: " .. configured_err)
  end
  if state then
    local owned, ownership = process_is_owned(state)
    vim.list_extend(lines, {
      "PID: " .. state.pid .. " (" .. ownership .. ")",
      "Generation: " .. state.generation,
      "Started: " .. state.started_at,
    })
    if not owned then
      table.insert(lines, "PID warning: state must not be used to signal this process")
    end
  end
  if not url then
    table.insert(lines, "HTTP backend: inactive")
    notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end
  probe_health(url, function(health, detail)
    table.insert(lines, "HTTP backend: " .. detail.kind)
    table.insert(lines, "Health latency: " .. detail.latency_ms .. "ms")
    if health then
      table.insert(lines, "Server version: " .. (health.version or "unknown"))
      if state and state.local_version ~= "unknown" and health.version and state.local_version ~= health.version then
        table.insert(lines, "Version warning: stop the shared server and use OpenCode again to launch the updated executable")
      end
    end
    notify(table.concat(lines, "\n"), health and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end

local function move_terminal(position)
  if position ~= "default" and not terminal_sizes[position] then
    notify("Usage: :Opencode move " .. table.concat(terminal_positions, "|"), vim.log.levels.ERROR)
    return
  end
  terminal_position = position
  if tui_valid() then
    local_tui.term.opts = vim.tbl_deep_extend("force", local_tui.term.opts, terminal_opts(position).win)
    local_tui.term:hide()
    local_tui.term:show()
  end
  notify("Moved local OpenCode terminal to " .. position, vim.log.levels.INFO)
end

local function complete_opencode(arg_lead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  if words[2] == "move" and (cmdline:match("%s$") or #words >= 3) then
    return vim.tbl_filter(function(position)
      return vim.startswith(position, arg_lead)
    end, terminal_positions)
  end
  return vim.tbl_filter(function(action)
    return vim.startswith(action, arg_lead)
  end, { "ask", "info", "move", "reload", "select", "start", "stop", "toggle" })
end

local function run_opencode_command(opts)
  local action = opts.fargs[1] or ""
  if action == "" or action == "toggle" then
    show_local_tui(true)
  elseif action == "start" then
    show_local_tui(false)
  elseif action == "stop" then
    stop_shared_server()
  elseif action == "info" then
    show_info()
  elseif action == "reload" then
    reload_current_directory(function(ok, message)
      notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  elseif action == "move" then
    move_terminal(opts.fargs[2] or "default")
  elseif action == "ask" then
    require("opencode").ask()
  elseif action == "select" then
    require("opencode").select()
  else
    require("opencode").command(table.concat(opts.fargs, " "))
  end
end

vim.g.opencode_opts = {
  server = {
    url = function(callback)
      local state = read_state()
      callback(state and state.url or nil)
    end,
    ensure = function(callback)
      ensure_backend(function(ok, err)
        callback(ok, err)
      end)
    end,
    start = false,
  },
}

vim.api.nvim_create_user_command("Opencode", run_opencode_command, {
  complete = complete_opencode,
  desc = "Control the local OpenCode TUI and shared server",
  force = true,
  nargs = "*",
})
vim.api.nvim_create_user_command("OpenCodeStart", function()
  show_local_tui(false)
end, { desc = "Start the shared OpenCode server and local TUI", force = true })
vim.api.nvim_create_user_command("OpenCodeStop", stop_shared_server, {
  desc = "Stop the shared OpenCode server and close the local TUI",
  force = true,
})
vim.api.nvim_create_user_command("OpenCodeInfo", show_info, {
  desc = "Show live OpenCode server information without starting it",
  force = true,
})
vim.api.nvim_create_user_command("OpenCodeReload", function()
  reload_current_directory(function(ok, message)
    notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end, {
  desc = "Reload the current OpenCode directory instance without restarting the shared server",
  force = true,
})

-- Narrow test seam for the headless lifecycle regression script. It is only
-- installed when explicitly requested before this configuration is sourced.
if vim.g.mkchad_opencode_test_api then
  vim.g.mkchad_opencode_test_api = {
    acquire_lock = acquire_lock,
    lock_is_owned = lock_is_owned,
    paths = paths,
    process_listens_on_port = process_listens_on_port,
    port_is_available = port_is_available,
    process_is_owned = process_is_owned,
    release_lock = release_lock,
    spawn_server = spawn_server,
    select_port = select_port,
    terminate_generation = terminate_generation,
    read_state = read_state,
    write_state = write_state,
    ensure_local_tui = ensure_local_tui,
    reload_current_directory = reload_current_directory,
    tui_valid = tui_valid,
  }
end
