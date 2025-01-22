require('possession').setup({
  autosave = {
    current = true,
    cwd = function() -- Prevent overwritting an existing cwd session
          return not require('possession.session').exists(require('possession.paths').cwd_session_name())
    end,
    on_load = true,
    on_quit = true,
  },
  autoload = "last_cwd",
  commands = {
    save = "SSave",
    load = "SLoad",
    delete = "SDelete",
    list = "SList",
  },
})

local o = vim.o
o.sessionoptions = "blank,buffers,curdir,tabpages,winsize"

require('telescope').load_extension('possession')
