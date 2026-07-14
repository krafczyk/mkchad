local config = assert(arg[1], "pass the MkChad config path")
local mode = arg[2] or "parent"
local control = arg[3]
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local function acquire(callback)
  local done = false
  lifecycle.acquire_lock(function(ok, err)
    done = true
    callback(ok, err)
  end)
  assert(vim.wait(3000, function()
    return done
  end, 10), "lock callback timed out")
end

if mode == "owner" then
  acquire(function(ok, err)
    assert(ok, err)
  end)
  vim.fn.writefile({ tostring(vim.fn.getpid()) }, control .. ".ready")
  assert(vim.wait(60000, function()
    return vim.uv.fs_stat(control .. ".release") ~= nil
  end, 20), "owner did not receive release request")
  lifecycle.release_lock()
  vim.fn.writefile({ "released" }, control .. ".done")
  vim.cmd("qa!")
end

if mode == "contender" then
  acquire(function(ok, err)
    vim.fn.writefile({ ok and "acquired" or "blocked", err or "" }, control .. ".result")
    if ok then
      lifecycle.release_lock()
    end
  end)
  vim.cmd("qa!")
end

local root = lifecycle.paths().root
assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
local script = vim.fn.fnamemodify(arg[0], ":p")
local prefix = vim.fs.joinpath(root, "lease-cross-process")

local function remove(path)
  vim.uv.fs_unlink(path)
end

local function start_worker(worker_mode)
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script, config, worker_mode, prefix })
  assert(job > 0, "failed to start " .. worker_mode .. " worker")
  return job
end

local function wait_for_file(path, timeout, message)
  assert(vim.wait(timeout, function()
    return vim.uv.fs_stat(path) ~= nil
  end, 20), message)
end

local function run_contender(expected)
  remove(prefix .. ".result")
  local job = start_worker("contender")
  assert(vim.wait(4000, function()
    return vim.fn.jobwait({ job }, 0)[1] ~= -1
  end, 20), "contender did not exit")
  wait_for_file(prefix .. ".result", 1000, "contender did not record its result")
  local result = vim.fn.readfile(prefix .. ".result")[1]
  assert(result == expected, "expected contender to be " .. expected .. ", got " .. tostring(result))
end

for _, suffix in ipairs({ ".ready", ".release", ".done", ".result" }) do
  remove(prefix .. suffix)
end

local owner_job = start_worker("owner")
wait_for_file(prefix .. ".ready", 3000, "lease owner did not acquire the lock")
vim.wait(31200, function()
  return false
end, 20)
assert(vim.fn.jobwait({ owner_job }, 0)[1] == -1, "lease owner exited before the renewed 30-second lease")
run_contender("blocked")

vim.fn.writefile({ "release" }, prefix .. ".release")
assert(vim.wait(4000, function()
  return vim.fn.jobwait({ owner_job }, 0)[1] ~= -1
end, 20), "lease owner did not release the lock")
wait_for_file(prefix .. ".done", 1000, "lease owner did not confirm release")
run_contender("acquired")

remove(prefix .. ".ready")
remove(prefix .. ".release")
local dead_owner_job = start_worker("owner")
wait_for_file(prefix .. ".ready", 3000, "dead-owner fixture did not acquire the lock")
assert(vim.uv.kill(vim.fn.jobpid(dead_owner_job), "sigkill"))
assert(vim.wait(3000, function()
  return vim.fn.jobwait({ dead_owner_job }, 0)[1] ~= -1
end, 20), "dead-owner fixture was not reaped")
run_contender("acquired")

vim.cmd("qa!")
