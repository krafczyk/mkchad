require "nvchad.options"

-- add yours here!

local o = vim.o
o.cursorlineopt ='both' -- to enable cursorline!

-- Reserve a space in the gutter
--vim.opt.signcolumn = 'yes'

-- Keep the cursor in the middle of the screen
o.so = 999

-- Add quick option for repeating previous command buffer action
vim.api.nvim_set_keymap('n', ',', '@@', { noremap = false, silent = false })

-- How I like searching to be done
o.incsearch = true
o.hlsearch = true
