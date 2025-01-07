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

-- Clear location list
map("n", "<leader>cl", function()
  vim.fn.setloclist(0, {})
end, { silent = true, desc = "Clear location list"})

-- Populate location list with diagnostics
map("n", "<leader>pl", function()
  vim.diagnostic.setloclist()
end, { silent = true, desc = "Populate location list"})

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
