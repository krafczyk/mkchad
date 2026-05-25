local enable_providers = {
  "python3_provider",
  "node_provider",
}
for _, plugin in pairs(enable_providers) do
  vim.g["loaded_" .. plugin] =nil
  vim.cmd("runtime " .. plugin)
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
