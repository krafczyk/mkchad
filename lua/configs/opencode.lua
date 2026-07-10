local opencode_host = "127.0.0.1"
local opencode_port_min = 49152
local opencode_port_max = 65535

local function port_is_available(port)
  local tcp = vim.uv.new_tcp()
  if not tcp then
    return false
  end

  local ok = tcp:bind(opencode_host, port)
  tcp:close()

  return ok == 0
end

local function pick_random_open_port()
  math.randomseed(os.time() + vim.fn.getpid())

  for _ = 1, 100 do
    local port = math.random(opencode_port_min, opencode_port_max)

    if port_is_available(port) then
      return port
    end
  end

  error("Unable to find an available port for opencode", 0)
end

local function get_opencode_port()
  local env_port = vim.env.OPENCODE_PORT

  if env_port and env_port ~= "" then
    local port = tonumber(env_port)

    if port and port >= 1 and port <= 65535 and port % 1 == 0 then
      return port
    end

    vim.notify("Ignoring invalid OPENCODE_PORT: " .. env_port, vim.log.levels.WARN, { title = "opencode" })
  end

  return pick_random_open_port()
end

local opencode_port = get_opencode_port()
local opencode_url = ("http://%s:%d"):format(opencode_host, opencode_port)
local opencode_web_cmd = { "opencode", "web", "--hostname", opencode_host, "--port", tostring(opencode_port) }
local opencode_attach_cmd = { "opencode", "attach", opencode_url }
local opencode_terminal_position = "default"
local opencode_server_job_id
local opencode_server_pid
local opencode_server_starting = false
local opencode_server_start_callbacks = {}

local function get_default_opencode_terminal_position()
  if vim.o.columns >= vim.o.lines then
    return "bottom"
  end

  return "right"
end

local function resolve_opencode_terminal_position(position)
  if position == "default" then
    return get_default_opencode_terminal_position()
  end

  return position
end

local opencode_terminal_sizes = {
  bottom = { height = 0.35 },
  top = { height = 0.35 },
  left = { width = 0.35 },
  right = { width = 0.35 },
  float = { height = 0.9, width = 0.9 },
}

local opencode_terminal_positions = vim.tbl_keys(opencode_terminal_sizes)
table.insert(opencode_terminal_positions, "default")
table.sort(opencode_terminal_positions)

local function snacks_terminal_opts(position)
  position = resolve_opencode_terminal_position(position or opencode_terminal_position)

  return {
    win = vim.tbl_deep_extend("force", {
      position = position,
      enter = false,
    }, opencode_terminal_sizes[position] or {}),
  }
end

local function get_opencode_terminal(create)
  return require("snacks.terminal").get(
    opencode_attach_cmd,
    vim.tbl_deep_extend("force", snacks_terminal_opts(), {
      create = create,
    })
  )
end

local function server_is_running()
  return opencode_server_job_id and vim.fn.jobwait({ opencode_server_job_id }, 0)[1] == -1
end

local function resolve_server_start_callbacks(started)
  local callbacks = opencode_server_start_callbacks
  opencode_server_start_callbacks = {}

  for _, callback in ipairs(callbacks) do
    callback(started)
  end
end

local function stop_opencode_server()
  local job_id = opencode_server_job_id
  local was_starting = opencode_server_starting

  opencode_server_job_id = nil
  opencode_server_pid = nil
  opencode_server_starting = false

  if was_starting then
    resolve_server_start_callbacks(false)
  end

  if job_id then
    vim.fn.jobstop(job_id)
  end
end

local function fail_opencode_server_start(job_id, message)
  if opencode_server_job_id ~= job_id then
    return
  end

  stop_opencode_server()
  vim.notify(message, vim.log.levels.ERROR, { title = "opencode" })
end

local function wait_for_opencode_server(job_id, attempts_remaining)
  local tcp = vim.uv.new_tcp()
  if not tcp then
    fail_opencode_server_start(job_id, "Unable to check whether opencode web is ready")
    return
  end

  local function on_connect(err)
    if not tcp:is_closing() then
      tcp:close()
    end

    vim.schedule(function()
      if opencode_server_job_id ~= job_id then
        return
      end

      if not err then
        opencode_server_starting = false
        resolve_server_start_callbacks(true)
      elseif attempts_remaining == 0 then
        fail_opencode_server_start(job_id, "Timed out waiting for opencode web at " .. opencode_url)
      else
        vim.defer_fn(function()
          wait_for_opencode_server(job_id, attempts_remaining - 1)
        end, 100)
      end
    end)
  end

  local ok = pcall(function()
    tcp:connect(opencode_host, opencode_port, on_connect)
  end)
  if not ok then
    on_connect("Unable to connect")
  end
end

local function start_opencode_server(callback)
  if server_is_running() then
    callback(true)
    return
  end

  table.insert(opencode_server_start_callbacks, callback)
  if opencode_server_starting then
    return
  end

  opencode_server_starting = true
  local job_id = vim.fn.jobstart(opencode_web_cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if opencode_server_job_id ~= job_id then
          return
        end

        local was_starting = opencode_server_starting
        opencode_server_job_id = nil
        opencode_server_pid = nil
        opencode_server_starting = false

        if was_starting then
          resolve_server_start_callbacks(false)
          vim.notify("opencode web exited before becoming ready (code " .. code .. ")", vim.log.levels.ERROR, {
            title = "opencode",
          })
        else
          vim.notify("opencode web exited (code " .. code .. ")", vim.log.levels.WARN, { title = "opencode" })
        end
      end)
    end,
  })

  if job_id <= 0 then
    opencode_server_starting = false
    resolve_server_start_callbacks(false)
    vim.notify("Failed to start opencode web", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  opencode_server_job_id = job_id
  opencode_server_pid = vim.fn.jobpid(job_id)
  wait_for_opencode_server(job_id, 50)
end

local function move_opencode_terminal(position)
  if position ~= "default" and not opencode_terminal_sizes[position] then
    vim.notify(
      "Usage: :Opencode move " .. table.concat(opencode_terminal_positions, "|"),
      vim.log.levels.ERROR,
      { title = "opencode" }
    )
    return
  end

  opencode_terminal_position = position

  local term = get_opencode_terminal(false)
  if not term then
    vim.notify("opencode terminal will open at " .. position, vim.log.levels.INFO, { title = "opencode" })
    return
  end

  term.opts = vim.tbl_deep_extend("force", term.opts, snacks_terminal_opts(position).win)

  if term:valid() then
    term:hide()
    term:show()
  end

  vim.notify("Moved opencode terminal to " .. position, vim.log.levels.INFO, { title = "opencode" })
end

local function complete_opencode(arg_lead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })

  if words[2] == "move" and (cmdline:match("%s$") or #words >= 3) then
    return vim.tbl_filter(function(position)
      return vim.startswith(position, arg_lead)
    end, opencode_terminal_positions)
  end

  local actions = { "ask", "move", "select", "start", "stop", "toggle" }
  return vim.tbl_filter(function(action)
    return vim.startswith(action, arg_lead)
  end, actions)
end

local function start_opencode_terminal()
  start_opencode_server(function(started)
    if not started then
      return
    end

    local term, created = get_opencode_terminal(true)

    if term and not created then
      term:show()
    end
  end)
end

local function close_opencode_terminal()
  local term = get_opencode_terminal(false)

  if term then
    term:close()
  end
end

local function stop_opencode_terminal()
  close_opencode_terminal()
  stop_opencode_server()
end

local function toggle_opencode_terminal()
  local term = get_opencode_terminal(false)
  if term then
    term:toggle()
    return
  end

  start_opencode_server(function(started)
    if started then
      require("snacks.terminal").toggle(opencode_attach_cmd, snacks_terminal_opts())
    end
  end)
end

local function show_opencode_info()
  if server_is_running() then
    vim.notify(
      table.concat({
        "OpenCode is running.",
        "PID: " .. opencode_server_pid,
        "Host: " .. opencode_host,
        "Port: " .. opencode_port,
        "URL: " .. opencode_url,
      }, "\n"),
      vim.log.levels.INFO,
      { title = "OpenCode" }
    )
    return
  end

  vim.notify(
    table.concat({ "OpenCode is not running.", "Host: " .. opencode_host, "Port: " .. opencode_port }, "\n"),
    vim.log.levels.WARN,
    { title = "OpenCode" }
  )
end

local function run_opencode_command(opts)
  local opencode = require("opencode")
  local action = opts.fargs[1] or ""

  if action == "" or action == "toggle" then
    toggle_opencode_terminal()
  elseif action == "select" then
    opencode.select()
  elseif action == "start" then
    start_opencode_terminal()
  elseif action == "stop" then
    stop_opencode_terminal()
  elseif action == "ask" then
    opencode.ask()
  elseif action == "move" then
    move_opencode_terminal(opts.fargs[2] or "default")
  else
    opencode.command(table.concat(opts.fargs, " "))
  end
end

vim.g.opencode_opts = {
  server = {
    url = opencode_url,
    start = start_opencode_terminal,
    stop = stop_opencode_terminal,
    toggle = toggle_opencode_terminal,
  },
}

-- vim.o.autoread = true -- Required for `opts.events.reload`

vim.api.nvim_create_user_command("Opencode", run_opencode_command, {
  complete = complete_opencode,
  desc = "Control opencode",
  force = true,
  nargs = "*",
})

vim.api.nvim_create_user_command("OpenCodeStart", start_opencode_terminal, {
  desc = "Start OpenCode web and attach the TUI",
  force = true,
})

vim.api.nvim_create_user_command("OpenCodeStop", stop_opencode_terminal, {
  desc = "Stop OpenCode web and close the TUI",
  force = true,
})

vim.api.nvim_create_user_command("OpenCodeInfo", show_opencode_info, {
  desc = "Show OpenCode server information",
  force = true,
})

vim.api.nvim_create_autocmd("ExitPre", {
  group = vim.api.nvim_create_augroup("opencode_server", { clear = true }),
  callback = stop_opencode_server,
})
