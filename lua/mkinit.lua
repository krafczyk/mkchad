local enable_providers = {
  "python3_provider",
  "node_provider",
}
for _, plugin in pairs(enable_providers) do
  vim.g["loaded_" .. plugin] =nil
  vim.cmd("runtime " .. plugin)
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local path_separator = package.config:sub(1, 1) == "\\" and ";" or ":"

local function split_path(value)
  local paths = {}

  for path in (value or ""):gmatch("[^" .. path_separator .. "]+") do
    if path ~= "" then
      table.insert(paths, path)
    end
  end

  return paths
end

local function set_path(paths)
  vim.env.PATH = table.concat(paths, path_separator)
end

local function remove_path(path)
  local paths = {}

  for _, candidate in ipairs(split_path(vim.env.PATH)) do
    if candidate ~= path then
      table.insert(paths, candidate)
    end
  end

  set_path(paths)
end

local function prepend_path(path)
  remove_path(path)

  local paths = split_path(vim.env.PATH)
  table.insert(paths, 1, path)
  set_path(paths)
end

local function append_path(path)
  remove_path(path)

  local paths = split_path(vim.env.PATH)
  table.insert(paths, path)
  set_path(paths)
end

local function get_node_global_key()
  if vim.fn.executable("node") ~= 1 then
    return nil
  end

  local result = vim.system({
    "node",
    "-p",
    "process.platform + '-' + process.arch + '-node' + process.versions.node.split('.')[0]",
  }, { text = true }):wait()

  if result.code ~= 0 then
    return nil
  end

  local key = trim(result.stdout)
  if key == "" then
    return nil
  end

  return key
end

local function env_or_default(name, default)
  local value = vim.env[name]

  if value == nil or value == "" then
    return default
  end

  return value
end

do
  local home = vim.env.HOME or vim.fn.expand("~")
  local node_global_key = get_node_global_key()

  vim.env.XDG_CACHE_HOME = env_or_default("XDG_CACHE_HOME", home .. "/.local/cache")
  vim.env.OPENCODE_CONFIG = env_or_default("OPENCODE_CONFIG", home .. "/.config/mkchad/opencode.jsonc")
  append_path(vim.fn.stdpath("data") .. "/mason/bin")

  if node_global_key then
    local npm_global_base = env_or_default(
      "MSK_NPM_GLOBAL_BASE",
      env_or_default("MSK_NPM_GLOBAL_ROOT", home .. "/.local/share/msk_containers/npm-global")
    )
    local selected_suffix = "/" .. node_global_key
    local npm_global_prefix = npm_global_base
    if npm_global_base:sub(-#selected_suffix) ~= selected_suffix then
      npm_global_prefix = npm_global_base .. selected_suffix
    end

    vim.fn.mkdir(npm_global_prefix, "p")
    vim.env.MSK_NPM_GLOBAL_ROOT = npm_global_prefix
    vim.env.NPM_CONFIG_PREFIX = npm_global_prefix
    prepend_path(npm_global_prefix .. "/bin")
  end
end

-- Define numbertoggle method
-- (Changes line numbers to relative when in normal mode.)
local numbertoggle = vim.api.nvim_create_augroup("numbertoggle", {
  clear = true,
})

local function set_relativenumber(enabled)
  if vim.wo.number then
    vim.wo.relativenumber = enabled
  end
end

vim.api.nvim_create_autocmd({
  "BufEnter",
  "FocusGained",
  "InsertLeave",
  "WinEnter",
}, {
  group = numbertoggle,
  callback = function()
    if vim.fn.mode() ~= "i" then
      set_relativenumber(true)
    end
  end,
})

vim.api.nvim_create_autocmd({
  "BufLeave",
  "FocusLost",
  "InsertEnter",
  "WinLeave",
}, {
  group = numbertoggle,
  callback = function()
    set_relativenumber(false)
  end,
})

-- Define swap/backup/undo file behavior
local state = vim.fn.stdpath("state")
local cache = vim.fn.stdpath("cache")

vim.opt.backup = true
vim.opt.writebackup = true -- keep a safety net
vim.opt.swapfile = true
vim.opt.undofile = true -- persistent undo

vim.opt.backupdir = state .. "/backup//" -- double // = auto-mkdir + file shrub
vim.opt.directory = state .. "/swap//"
vim.opt.undodir = cache .. "/undo//"
