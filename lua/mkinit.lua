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
vim.api.nvim_exec([[
augroup numbertoggle
  autocmd!
  autocmd BufEnter,FocusGained,InsertLeave,WinEnter * if &nu && mode() != "i" | set rnu   | endif
  autocmd BufLeave,FocusLost,InsertEnter,WinLeave   * if &nu                  | set nornu | endif
augroup END
]], false)

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
