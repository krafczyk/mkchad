local uv = vim.uv
local host = "127.0.0.1"
local preferred_port = 4096
local startup_timeout_ms = 15000
local health_attempts = 30
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
  return value:gsub("\\", "\\\\"):gsub('"', '\\"')
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

local function port_is_available(port)
  local tcp = uv.new_tcp()
  if not tcp then
    return false
  end
  local ok = tcp:bind(host, port)
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

local function process_is_owned(state)
  if not state or state.hostname ~= hostname() or type(state.pid) ~= "number" or state.pid <= 0 then
    return false, "invalid managed PID"
  end
  if not pid_is_live(state.pid) then
    return false, "PID is not live"
  end
  local command = read_file("/proc/" .. state.pid .. "/cmdline")
  if command then
    command = command:gsub("%z", " ")
    if not command:find("opencode", 1, true)
      or not command:find("serve", 1, true)
      or not command:find("--port " .. state.port, 1, true)
    then
      return false, "PID command does not match managed opencode serve"
    end
  end
  return true, "verified"
end

local lock_token
local function lock_is_owned()
  local owner_content = read_file(paths().lock_owner)
  if not owner_content then
    return false
  end
  local ok, owner = pcall(vim.json.decode, owner_content)
  return ok and owner.token == lock_token and owner.pid == vim.fn.getpid()
end

local function release_lock()
  if lock_token and lock_is_owned() then
    uv.fs_unlink(paths().lock_owner)
    uv.fs_rmdir(paths().lock)
  end
  lock_token = nil
end

local function lock_is_stale()
  local content = read_file(paths().lock_owner)
  local ok, owner = content and pcall(vim.json.decode, content)
  if not ok or type(owner) ~= "table" or owner.hostname ~= hostname() or type(owner.pid) ~= "number" then
    return true
  end
  if owner.acquired_at_ns and uv.hrtime() - owner.acquired_at_ns > startup_timeout_ms * 1000000 then
    return true
  end
  return not pid_is_live(owner.pid)
end

local function acquire_lock(callback, retried)
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
    }
    local wrote, write_err = write_private(state_paths.lock_owner, vim.json.encode(owner))
    if not wrote then
      release_lock()
      callback(false, "Unable to write OpenCode startup lock: " .. (write_err or "unknown error"))
      return
    end
    callback(true)
    return
  end
  if not retried and lock_is_stale() then
    uv.fs_unlink(state_paths.lock_owner)
    uv.fs_rmdir(state_paths.lock)
    acquire_lock(callback, true)
    return
  end
  callback(false, "OpenCode startup is already in progress")
end

local function wait_for_health(url, remaining, callback)
  probe_health(url, function(health, detail)
    if health then
      callback(health, detail)
    elseif remaining <= 0 then
      callback(nil, detail)
    else
      vim.defer_fn(function()
        wait_for_health(url, remaining - 1, callback)
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

local function select_port(state)
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
  if state and port_is_available(state.port) then
    return state.port, "persisted"
  end
  if port_is_available(preferred_port) then
    return preferred_port, "preferred 4096"
  end
  for _ = 1, 20 do
    local candidate = math.random(49152, 65535)
    if port_is_available(candidate) then
      return candidate, "fallback"
    end
  end
  return nil, nil, "Unable to find an available OpenCode port"
end

local function spawn_server(state, port_source, callback)
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
  local port, source, port_err = select_port(state)
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
  local managed = {
    schema = 1,
    hostname = hostname(),
    pid = pid,
    generation = generation,
    host = host,
    port = port,
    url = ("http://%s:%d"):format(host, port),
    port_source = source or port_source,
    started_at = iso_now(),
    cwd = vim.env.HOME or vim.fn.expand("~"),
    log = state_paths.log,
    executable = executable,
    local_version = version,
  }
  local wrote, write_err = write_state(managed)
  if not wrote then
    uv.kill(pid, "sigterm")
    callback(nil, write_err)
    return
  end
  wait_for_health(managed.url, health_attempts, function(health, detail)
    if health then
      managed.server_version = health.version
      write_state(managed)
      callback(managed)
    else
      remove_matching_state(generation)
      callback(nil, "OpenCode did not become healthy at " .. managed.url .. " (" .. detail.kind .. "); see " .. state_paths.log)
    end
  end)
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
  return local_tui and local_tui.term and local_tui.term:valid()
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
  local_tui = { term = term, url = state.url, directory = cwd, generation = state.generation, command = command }
  if created then
    vim.defer_fn(function()
      callback(true)
    end, local_tui_bootstrap_ms)
  else
    callback(true)
  end
end

local function managed_state_if_healthy(state, callback)
  if not state then
    callback(nil)
    return
  end
  probe_health(state.url, function(health)
    callback(health and state or nil)
  end)
end

local function ensure_backend(callback)
  table.insert(ensure_waiters, callback)
  if ensure_active then
    return
  end
  ensure_active = true
  local state = read_state()
  local requested, request_err = explicit_port()
  if request_err then
    finish_ensure(false, request_err)
    return
  end
  local function start_while_locked()
    local locked_state = read_state()
    managed_state_if_healthy(locked_state, function(rechecked)
      if rechecked then
        release_lock()
        ensure_local_tui(rechecked, function(ok, err)
          finish_ensure(ok, err, rechecked)
        end)
        return
      end
      spawn_server(locked_state, nil, function(started, start_err)
        release_lock()
        if not started then
          finish_ensure(false, start_err)
          return
        end
        ensure_local_tui(started, function(ok, err)
          finish_ensure(ok, err, started)
        end)
      end)
    end)
  end
  managed_state_if_healthy(state, function(healthy_state)
    if healthy_state then
      if requested and healthy_state.port ~= requested then
        finish_ensure(
          false,
          "A managed OpenCode server uses " .. healthy_state.url .. "; stop the shared server before changing OPENCODE_PORT"
        )
        return
      end
      ensure_local_tui(healthy_state, function(ok, err)
        finish_ensure(ok, err, healthy_state)
      end)
      return
    end
    acquire_lock(function(locked, lock_err)
      if not locked then
        local deadline = uv.hrtime() + startup_timeout_ms * 1000000
        local function wait_for_winner()
          local waiting_state = read_state()
          managed_state_if_healthy(waiting_state, function(winner)
            if winner then
              ensure_local_tui(winner, function(ok, err)
                finish_ensure(ok, err, winner)
              end)
            elseif uv.hrtime() >= deadline then
              acquire_lock(function(relocked, retry_err)
                if relocked then
                  start_while_locked()
                else
                  finish_ensure(false, retry_err or lock_err)
                end
              end)
            else
              vim.defer_fn(wait_for_winner, health_interval_ms)
            end
          end)
        end
        wait_for_winner()
        return
      end
      start_while_locked()
    end)
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
    uv.kill(state.pid, "sigterm")
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
          local still_owned = process_is_owned(state)
          if still_owned then
            uv.kill(state.pid, "sigkill")
            escalated = true
            remaining = 25
            vim.defer_fn(wait_for_stop, health_interval_ms)
          else
            release_lock()
            notify("Refusing to escalate an unverifiable shared OpenCode PID", vim.log.levels.ERROR)
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
  end, { "ask", "info", "move", "select", "start", "stop", "toggle" })
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
