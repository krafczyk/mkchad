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
local opencode_cmd = ("opencode --hostname %s --port %d"):format(opencode_host, opencode_port)

local snacks_terminal_opts = {
  win = {
    position = "right",
    enter = false,
    on_win = function(win)
      require("opencode.terminal").setup(win.win)
    end,
  },
}

vim.g.opencode_opts = {
  server = {
    url = opencode_url,
    start = function()
      require("snacks").terminal.open(opencode_cmd, snacks_terminal_opts)
    end,

    stop = function()
      local term = require("snacks").terminal.get(
        opencode_cmd,
        vim.tbl_deep_extend("force", snacks_terminal_opts, {
          create = false,
        })
      )

      if term then
        term:close()
      end
    end,

    toggle = function()
      require("snacks").terminal.toggle(opencode_cmd, snacks_terminal_opts)
    end,
  },
}

-- vim.o.autoread = true -- Required for `opts.events.reload`

vim.api.nvim_create_user_command("Opencode", function(opts)
  local opencode = require("opencode")
  local action = opts.args

  if action == "" or action == "select" then
    opencode.select()
  elseif action == "start" then
    opencode.start()
  elseif action == "stop" then
    opencode.stop()
  elseif action == "toggle" then
    opencode.toggle()
  elseif action == "ask" then
    opencode.ask()
  else
    opencode.command(action)
  end
end, {
  complete = function(arg_lead)
    local actions = { "ask", "select", "start", "stop", "toggle" }
    return vim.tbl_filter(function(action)
      return vim.startswith(action, arg_lead)
    end, actions)
  end,
  desc = "Control opencode",
  force = true,
  nargs = "?",
})
