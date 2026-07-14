local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local first, first_err = lifecycle.ensure_certificate_material()
assert(first, first_err)
local stable, stable_err = lifecycle.ensure_certificate_material()
assert(stable == first, stable_err or "valid certificate material rotated")

local paths = lifecycle.paths()
vim.fn.writefile({ "invalid CA" }, paths.ca)
assert(vim.uv.fs_chmod(paths.ca, 384))
local replacement, replacement_err = lifecycle.ensure_certificate_material()
assert(replacement and replacement ~= first, replacement_err or "invalid certificate material was not regenerated")
for _, path in ipairs({ paths.ca, paths.ca_store, paths.server_store, paths.server_cert, paths.password }) do
  local stat = assert(vim.uv.fs_stat(path), path)
  assert(stat.mode % 512 == 384, path .. " is not mode 0600")
end
vim.cmd("qa!")
