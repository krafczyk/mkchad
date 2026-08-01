local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = vim.fs.joinpath(root, "lua", "?.lua") .. ";" .. package.path
vim.opt.runtimepath:prepend(root)
package.loaded["mkchad.opencode.contracts"] = nil

local contracts = require "mkchad.opencode.contracts"
local expected_revision = "37033dc157ac4c05c1e1525fe2fc9e87ae83e2ac"

assert(contracts.opencode_nvim_revision == expected_revision, "owner declaration must pin the parent gitlink revision")

local plugin_source = table.concat(vim.fn.readfile(vim.fs.joinpath(root, "lua", "plugins", "init.lua")), "\n")
assert(
  plugin_source:find("commit = opencode_contracts.opencode_nvim_revision", 1, true),
  "Lazy plugin specification must consume the owner declaration"
)

print "opencode contract tests passed"
