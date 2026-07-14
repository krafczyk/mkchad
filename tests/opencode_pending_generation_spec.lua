local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 5000, function()
    return done
  end, 10), "operation timed out")
  return unpack(values)
end

local function process_live(pid)
  local stat = vim.uv.fs_stat("/proc/" .. pid .. "/stat") and vim.fn.readfile("/proc/" .. pid .. "/stat")[1]
  return stat ~= nil and stat:match("%)%s+(%a)") ~= "Z"
end

assert(vim.fn.mkdir(paths.root, "p", 448) ~= 0 or vim.uv.fs_stat(paths.root))
local fake = vim.fs.joinpath(paths.root, "pending-opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import time",
  "time.sleep(60)",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
local launch = assert(lifecycle.file_identity(fake))

local function start(port)
  local job = vim.fn.jobstart({ fake, "serve", "--hostname", "127.0.0.1", "--port", tostring(port) })
  local pid = vim.fn.jobpid(job)
  assert(vim.wait(2000, function()
    return lifecycle.proc_start_time(pid) ~= nil
  end, 10), "pending process did not start")
  vim.wait(50, function()
    return false
  end, 10)
  local process = assert(lifecycle.capture_process(pid, {
    port = port,
    executable = fake,
    executable_dev = launch.dev,
    executable_ino = launch.ino,
    local_version = "pending-test",
    log = paths.log,
  }))
  return job, process
end

local first_job, first = start(55001)
local second_job, second = start(55002)
local locked, lock_err = await(lifecycle.acquire_lock)
assert(locked, lock_err)

local pending = {
  schema = 2,
  hostname = (vim.uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_"),
  generation = "current-generation",
  boot_id = assert(lifecycle.current_boot_id()),
  backend = second,
}
assert(lifecycle.write_pending(pending))

-- Cleanup must ignore the caller's process fields and signal only the freshly
-- re-read, validated pending identity for the matching generation.
local caller = vim.deepcopy(pending)
caller.backend = first
local cleaned, cleanup_err = await(function(done)
  lifecycle.cleanup_failed_pair(caller, vim.uv.hrtime() + 5000000000, done)
end, 8000)
assert(cleaned, cleanup_err)
assert(not process_live(second.pid), "fresh pending identity was not stopped")
assert(process_live(first.pid), "cleanup signaled the caller-supplied stale identity")
assert(not vim.uv.fs_stat(paths.pending), "matching pending generation was not removed")

pending.backend = first
pending.generation = "newer-generation"
assert(lifecycle.write_pending(pending))
local stale = vim.deepcopy(pending)
stale.generation = "older-generation"
local stale_cleaned, stale_err = await(function(done)
  lifecycle.cleanup_failed_pair(stale, vim.uv.hrtime() + 1000000000, done)
end)
assert(not stale_cleaned and stale_err:find("generation changed", 1, true), stale_err)
assert(process_live(first.pid), "generation mismatch signaled the pending process")
assert(assert(lifecycle.read_pending()).generation == pending.generation)
assert(lifecycle.remove_matching_pending_while_locked(pending.generation, "pending test cleanup"))
lifecycle.release_lock()

if process_live(first.pid) then
  vim.fn.jobstop(first_job)
end
if process_live(second.pid) then
  vim.fn.jobstop(second_job)
end
vim.cmd("qa!")
