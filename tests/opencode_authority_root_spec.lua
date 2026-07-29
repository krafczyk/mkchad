local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()

local function remove(path)
  vim.fn.delete(path, "rf")
  vim.uv.fs_unlink(path)
end

local function parent(path)
  return vim.fs.dirname(path)
end

assert(vim.fn.mkdir(parent(paths.root), "p", 448) ~= 0 or vim.uv.fs_stat(parent(paths.root)))

local launch_marker = vim.fs.joinpath(parent(paths.root), "authority-root-launch-marker")
local fake = vim.fs.joinpath(parent(paths.root), "opencode")
vim.fn.writefile({
  "#!/bin/sh",
  "touch " .. vim.fn.shellescape(launch_marker),
  "exit 97",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = parent(paths.root) .. ":" .. vim.env.PATH

local function assert_refused(name, create, inspect)
  remove(paths.root)
  remove(launch_marker)
  create()
  local before = assert(vim.uv.fs_lstat(paths.root), name .. " fixture was not created")
  local state_paths, err
  lifecycle.spawn_pair(nil, vim.uv.hrtime() + 1000000000, function(started, start_err)
    state_paths, err = started, start_err
  end)
  assert(not state_paths and tostring(err):find("authority", 1, true), name .. " reached startup: " .. tostring(err))
  assert(not vim.uv.fs_stat(launch_marker), name .. " reached broker or backend launch")
  assert(
    not vim.uv.fs_stat(paths.launch) and not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.state),
    name .. " wrote lifecycle intent or state"
  )
  local after = assert(vim.uv.fs_lstat(paths.root), name .. " unsafe entry was removed")
  assert(
    before.type == after.type and before.dev == after.dev and before.ino == after.ino,
    name .. " unsafe entry changed"
  )
  inspect(after)
end

assert_refused("pre-existing symlink", function()
  local target = vim.fs.joinpath(parent(paths.root), "authority-root-symlink-target")
  remove(target)
  assert(vim.fn.mkdir(target, "p", 448) ~= 0 or vim.uv.fs_stat(target))
  assert(vim.uv.fs_symlink(target, paths.root))
end, function(entry)
  assert(entry.type == "link")
end)

assert_refused("wrong type", function()
  vim.fn.writefile({ "unsafe root file" }, paths.root)
  assert(vim.uv.fs_chmod(paths.root, 384))
end, function(entry)
  assert(entry.type == "file")
end)

assert_refused("unsafe mode", function()
  assert(vim.fn.mkdir(paths.root, "p", 493) ~= 0 or vim.uv.fs_stat(paths.root))
  assert(vim.uv.fs_chmod(paths.root, 493))
end, function(entry)
  assert(entry.type == "directory" and entry.mode % 512 == 493)
end)

-- A non-owner cannot create a wrong-EUID entry credential-free. Production
-- validation remains covered by ensure_state_dir's uid == uv.getuid() check.
remove(paths.root)
vim.cmd "qa!"
