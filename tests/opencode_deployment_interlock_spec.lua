local root = assert(arg[1], "pass the MkChad repository root")
local config = vim.fs.joinpath(root, "lua", "configs", "opencode.lua")
local ffi = require "ffi"

pcall(ffi.cdef, "int flock(int fd, int operation);")

local flock_shared = 1
local flock_exclusive = 2
local flock_nonblocking = 4
local flock_unlock = 8

local scratch_root = "/tmp/mkchad-v1"
assert(vim.fn.mkdir(scratch_root, "p", 448) ~= 0 or vim.uv.fs_stat(scratch_root))
local scratch_stat = assert(vim.uv.fs_lstat(scratch_root))
assert(
  scratch_stat.type == "directory" and scratch_stat.uid == vim.uv.getuid() and bit.band(scratch_stat.mode, 18) == 0
)
local work = vim.fs.joinpath(scratch_root, "deployment-interlock-" .. vim.fn.getpid())
assert(not vim.uv.fs_lstat(work), "test work directory already exists")
vim.env.XDG_STATE_HOME = vim.fs.joinpath(work, "state")

vim.g.mkchad_opencode_test_api = true
vim.g.mkchad_opencode_test_timeout_ms = 1000
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(
    vim.wait(timeout or 5000, function()
      return done
    end, 10),
    "operation timed out"
  )
  return unpack(values)
end

local function open_deployment_lock()
  assert(
    vim.fn.mkdir(vim.fs.dirname(paths.deployment_lock), "p", 448) ~= 0
      or vim.uv.fs_stat(vim.fs.dirname(paths.deployment_lock))
  )
  local fd = assert(vim.uv.fs_open(paths.deployment_lock, "a", 384))
  assert(vim.uv.fs_chmod(paths.deployment_lock, 384))
  return fd
end

local function lock(fd, operation)
  assert(ffi.C.flock(fd, operation + flock_nonblocking) == 0, "flock operation did not acquire")
end

local function unlock(fd)
  assert(ffi.C.flock(fd, flock_unlock) == 0)
  assert(vim.uv.fs_close(fd))
end

-- A deployment lock path must never redirect locking or chmod through a link.
assert(
  vim.fn.mkdir(vim.fs.dirname(paths.deployment_lock), "p", 448) ~= 0
    or vim.uv.fs_stat(vim.fs.dirname(paths.deployment_lock))
)
local symlink_target = paths.deployment_lock .. ".target"
assert(vim.fn.writefile({ "unrelated" }, symlink_target) == 0)
assert(vim.uv.fs_chmod(symlink_target, 420))
assert(vim.uv.fs_symlink(symlink_target, paths.deployment_lock))
local acquired, acquire_err = await(lifecycle.acquire_lock, 3000)
assert(not acquired and acquire_err:find("deployment lock path", 1, true), acquire_err)
assert(vim.uv.fs_lstat(paths.deployment_lock).type == "link")
assert(vim.uv.fs_stat(symlink_target).mode % 512 == 420, "deployment lock validation chmodded a link target")
assert(vim.uv.fs_unlink(paths.deployment_lock))
assert(vim.uv.fs_unlink(symlink_target))

-- Deployment owns this host-visible lock exclusively. A blocked start must
-- leave lifecycle authority absent rather than publishing partial service state.
local deployment_fd = open_deployment_lock()
lock(deployment_fd, flock_exclusive)
local started, start_err = await(lifecycle.ensure_server, 3000)
assert(not started and start_err:find("deployment lock", 1, true), start_err)
assert(not lifecycle.read_state() and not lifecycle.read_pending() and not lifecycle.read_launch_intent())
unlock(deployment_fd)

-- The legacy startup lock remains authoritative, while its holder retains the
-- shared deployment interlock until the bounded transition releases it.
acquired, acquire_err = await(lifecycle.acquire_lock, 3000)
assert(acquired, acquire_err)
local contender_fd = open_deployment_lock()
assert(
  ffi.C.flock(contender_fd, flock_exclusive + flock_nonblocking) ~= 0,
  "exclusive deployment lock acquired during a start transition"
)
lifecycle.release_lock()
lock(contender_fd, flock_exclusive)
unlock(contender_fd)

-- Once deployment releases its exclusive hold, the next bounded start lock
-- operation may proceed without carrying state from the blocked attempt.
acquired, acquire_err = await(lifecycle.acquire_lock, 3000)
assert(acquired, acquire_err)
lifecycle.release_lock()

assert(vim.fn.delete(work, "rf") == 0)

print "opencode deployment interlock tests passed"
