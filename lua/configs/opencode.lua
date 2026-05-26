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
local opencode_cmd = ("opencode --hostname %s --port %d"):format(opencode_host, opencode_port)
local opencode_terminal_position = "default"

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
      on_win = function(win)
        require("opencode.terminal").setup(win.win)
      end,
    }, opencode_terminal_sizes[position] or {}),
  }
end

local function get_opencode_terminal(create)
  return require("snacks").terminal.get(
    opencode_cmd,
    vim.tbl_deep_extend("force", snacks_terminal_opts(), {
      create = create,
    })
  )
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
  local term, created = get_opencode_terminal(true)

  if term and not created and not term:valid() then
    term:show()
  end
end

local function stop_opencode_terminal()
  local term = get_opencode_terminal(false)

  if term then
    term:close()
  end
end

local function toggle_opencode_terminal()
  require("snacks").terminal.toggle(opencode_cmd, snacks_terminal_opts())
end

local function run_opencode_command(opts)
  local opencode = require("opencode")
  local action = opts.fargs[1] or ""

  if action == "" or action == "toggle" then
    opencode.toggle()
  elseif action == "select" then
    opencode.select()
  elseif action == "start" then
    opencode.start()
  elseif action == "stop" then
    opencode.stop()
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
