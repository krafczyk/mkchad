-- The standalone command deliberately loads only this lifecycle asset.  It
-- never sources init.lua, user init files, plugin specifications, or UI code.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))

vim.g.mkchad_opencode_lifecycle_only = true

return dofile(vim.fs.joinpath(config_root, "lua", "configs", "opencode.lua"))
