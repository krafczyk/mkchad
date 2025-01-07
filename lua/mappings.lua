require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")


-- Hover Diagnostic Command
map("n", "<leader>d", vim.diagnostic.open_float)
map("n", "<leader>dn", vim.diagnostic.goto_next, { desc = "Go to next diagnostic"})
map("n", "<leader>dp", vim.diagnostic.goto_prev, { desc = "Go to prev diagnostic"})

-- Navigate location list
map("n", "<leader>ln", ":lnext<CR>", { silent = true, desc = "Go to next location in location list" })
map("n", "<leader>lp", ":lprev<CR>", { silent = true, desc = "Go to next location in location list" })

-- Clipboard reloader
local function reload_clipboard_provider()
  -- Unset the loaded clipboard provider
  vim.g.loaded_clipboard_provider = nil

  -- Reload the clipboard provider
  vim.cmd("runtime autoload/provider/clipboard.vim")

  -- Check if the clipboard provider was reloaded successfully
  local health_check = vim.fn["provider#clipboard#Executable"]()
  if health_check then
    vim.notify("Clipboard provider successfully reloaded.", vim.log.levels.INFO)
  else
    vim.notify("Failed to reload clipboard provider. Check your environment.", vim.log.levels.ERROR)
  end
end

vim.api.nvim_create_user_command("ReloadClipboard", reload_clipboard_provider, {})

-- Clear location list
map("n", "<leader>cl", function()
  vim.fn.setloclist(0, {})
end, { silent = true, desc = "Clear location list"})

-- Populate location list with diagnostics
map("n", "<leader>pl", function()
  vim.diagnostic.setloclist()
end, { silent = true, desc = "Populate location list"})

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
