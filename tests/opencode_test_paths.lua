local M = {}
local scratch_root = "/tmp/opencode-mkchad"

local function required_path(name, value)
  assert(type(value) == "string" and value ~= "", name .. " is required")
  return vim.fs.normalize(value)
end

function M.create_xdg_roots(value, roots)
  local task_root = required_path("MKCHAD_TEST_ROOT", value)
  assert(vim.fs.dirname(task_root) == scratch_root, "MKCHAD_TEST_ROOT must be a direct child of " .. scratch_root)

  local scratch_stat = assert(vim.uv.fs_lstat(scratch_root), scratch_root .. " is unavailable")
  assert(
    scratch_stat.type == "directory"
      and scratch_stat.uid == vim.uv.getuid()
      and bit.band(scratch_stat.mode, 18) == 0
      and vim.uv.fs_realpath(scratch_root) == scratch_root,
    scratch_root .. " must be a private current-user directory"
  )
  assert(not vim.uv.fs_lstat(task_root), "MKCHAD_TEST_ROOT must be a new private directory")
  local normalized, seen = {}, {}
  for name, value in pairs(roots) do
    local path = required_path(name, value)
    assert(vim.fs.dirname(path) == task_root, name .. " must be a direct child of MKCHAD_TEST_ROOT")
    assert(not seen[path], "XDG roots must be distinct")
    assert(not vim.uv.fs_lstat(path), name .. " must not already exist")
    seen[path] = true
    normalized[name] = path
  end
  assert(vim.uv.fs_mkdir(task_root, 448), "MKCHAD_TEST_ROOT could not be created")
  for _, path in pairs(normalized) do
    assert(vim.uv.fs_mkdir(path, 448))
  end
  return task_root, normalized
end

return M
