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
acquire(function(ok, err)
  assert(ok, err)
end)
local exact_owner = vim.json.decode(table.concat(vim.fn.readfile(lifecycle.paths().lock_owner), "\n"))
assert(type(exact_owner.lock_dev) == "string", "lock device identity was not serialized as a decimal string")
assert(type(exact_owner.lock_ino) == "string", "lock inode identity was not serialized as a decimal string")
assert(exact_owner.lock_ino == lifecycle.exact_lstat_inode(lifecycle.paths().lock), "lock inode lost precision")
lifecycle.release_lock()

-- Old launchers persisted rounded numeric identities. A well-formed owner
-- whose PID is dead remains immediately reclaimable without trusting those
-- rounded identity fields.
assert(vim.fn.mkdir(lifecycle.paths().lock, "p", 448) ~= 0)
local legacy_stat = assert(vim.uv.fs_stat(lifecycle.paths().lock))
local legacy_token = "legacy-numeric-lock"
local legacy_pid = 4194304
assert(not vim.uv.fs_stat("/proc/" .. legacy_pid), "legacy dead-PID fixture unexpectedly exists")
local legacy_now = math.floor(vim.uv.hrtime() / 1000000)
local legacy_owner = {
  token = legacy_token,
  pid = legacy_pid,
  hostname = (vim.uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_"),
  lock_dev = legacy_stat.dev,
  lock_ino = legacy_stat.ino,
  boot_id = lifecycle.current_boot_id(),
  acquired_at_unix_ms = os.time() * 1000,
  acquired_monotonic_ms = legacy_now,
}
local legacy_lease = {
  token = legacy_token,
  pid = legacy_pid,
  hostname = legacy_owner.hostname,
  lock_dev = legacy_stat.dev,
  lock_ino = legacy_stat.ino,
  boot_id = legacy_owner.boot_id,
  renewed_monotonic_ms = legacy_now,
  deadline_monotonic_ms = legacy_now + 30000,
}
vim.fn.writefile({ vim.json.encode(legacy_owner) }, lifecycle.paths().lock_owner)
vim.fn.writefile(
  { vim.json.encode(legacy_lease) },
  vim.fs.joinpath(lifecycle.paths().lock, "lease-" .. legacy_token .. ".json")
)
assert(vim.uv.fs_chmod(lifecycle.paths().lock_owner, 384))
assert(vim.uv.fs_chmod(vim.fs.joinpath(lifecycle.paths().lock, "lease-" .. legacy_token .. ".json"), 384))
acquire(function(ok, err)
  assert(ok, err)
end)
lifecycle.release_lock()
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
