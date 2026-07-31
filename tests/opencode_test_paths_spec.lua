local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = vim.fs.joinpath(root, "?.lua") .. ";" .. package.path

local test_paths = require "tests.opencode_test_paths"
local scratch_root = "/tmp/opencode-mkchad"
local suffix = tostring(vim.fn.getpid())

for _, path in ipairs {
  "/tmp/opencode-mkchad-outside/task",
  scratch_root,
  scratch_root .. "/nested/task",
} do
  local ok, err = pcall(test_paths.create_xdg_roots, path, {})
  assert(not ok and tostring(err):find("direct child", 1, true), path)
end

local ok, err = pcall(test_paths.create_xdg_roots, nil, {})
assert(not ok and tostring(err):find("MKCHAD_TEST_ROOT is required", 1, true))

local escape = scratch_root .. "/test-paths-symlink-" .. suffix
assert(not vim.uv.fs_lstat(escape))
assert(vim.uv.fs_symlink("/tmp", escape))
local escaped_ok, escaped_err = pcall(test_paths.create_xdg_roots, escape, {})
assert(vim.uv.fs_unlink(escape))
assert(not escaped_ok and tostring(escaped_err):find("new private directory", 1, true))

local requested_task_root = scratch_root .. "/test-paths-" .. suffix
local task_root, roots = test_paths.create_xdg_roots(requested_task_root, {
  XDG_CONFIG_HOME = requested_task_root .. "/config",
  XDG_STATE_HOME = requested_task_root .. "/state",
  XDG_RUNTIME_DIR = requested_task_root .. "/runtime",
})
assert(task_root == requested_task_root)
assert(roots.XDG_CONFIG_HOME == task_root .. "/config")
assert(vim.uv.fs_stat(roots.XDG_STATE_HOME).type == "directory")

local sibling_ok, sibling_err = pcall(test_paths.create_xdg_roots, scratch_root .. "/sibling-check-" .. suffix, {
  XDG_CONFIG_HOME = scratch_root .. "/other-task/config",
})
assert(not sibling_ok and tostring(sibling_err):find("direct child of MKCHAD_TEST_ROOT", 1, true))

local duplicate_root = scratch_root .. "/duplicate-check-" .. suffix
local duplicate_ok, duplicate_err = pcall(test_paths.create_xdg_roots, duplicate_root, {
  XDG_CONFIG_HOME = duplicate_root .. "/duplicate",
  XDG_STATE_HOME = duplicate_root .. "/duplicate",
})
assert(not duplicate_ok and tostring(duplicate_err):find("XDG roots must be distinct", 1, true))

print "OpenCode test path tests passed"
