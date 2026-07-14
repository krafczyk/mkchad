local config = assert(arg[1], "pass the MkChad config path")
local mode = assert(arg[2], "pass a worker mode")
local control = assert(arg[3], "pass a control prefix")
local input_path = arg[4]
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 10000, function()
    return done
  end, 10), mode .. " timed out")
  return unpack(values)
end

local function input()
  return vim.json.decode(table.concat(vim.fn.readfile(input_path), "\n"))
end

local function record(...)
  local values = { ... }
  for index, value in ipairs(values) do
    values[index] = tostring(value)
  end
  vim.fn.writefile(values, control .. ".result")
end

if mode == "contender" then
  local locked, lock_err = await(function(done)
    lifecycle.acquire_lock(done, nil, vim.uv.hrtime() + 500 * 1000000)
  end, 2000)
  if locked then
    lifecycle.release_lock()
  end
  record(locked and "acquired" or "blocked", lock_err or "")
  vim.cmd("qa!")
end

if mode == "owner" then
  local locked, lock_err = await(lifecycle.acquire_lock)
  assert(locked, lock_err)
  vim.fn.writefile({ "held" }, control .. ".marker")
  assert(vim.wait(60000, function()
    return vim.uv.fs_stat(control .. ".resume") ~= nil
  end, 10), "owner resume timed out")
  lifecycle.release_lock()
  record("released")
  vim.cmd("qa!")
end

if mode == "fd_loop" or mode == "release_loop" then
  local function fd_count()
    return #vim.fn.glob("/proc/" .. vim.fn.getpid() .. "/fd/*", true, true)
  end
  local before = fd_count()
  for _ = 1, 20 do
    local locked, lock_err
    if mode == "fd_loop" then
      locked, lock_err = await(function(done)
        lifecycle.acquire_lock(done, nil, vim.uv.hrtime() + 50 * 1000000)
      end, 1000)
      assert(not locked, "fd-loop contender unexpectedly acquired the fence")
    else
      locked, lock_err = await(lifecycle.acquire_lock)
      assert(locked, lock_err)
      lifecycle.release_lock()
    end
  end
  vim.wait(100, function()
    return false
  end, 10)
  record(before, fd_count())
  vim.cmd("qa!")
end

if mode == "successor" then
  local data = input()
  local locked, lock_err = await(lifecycle.acquire_lock)
  assert(locked, lock_err)
  local ok, err
  if data.pending then
    ok, err = lifecycle.write_pending(data.pending)
  else
    ok, err = lifecycle.write_state(data.state, "successor state publication")
  end
  lifecycle.release_lock()
  assert(ok, err)
  record("published")
  vim.cmd("qa!")
end

if mode == "reclaim" then
  lifecycle.set_test_hook("logical_reclaim", control .. ".marker", control .. ".resume")
  local locked, lock_err = await(lifecycle.acquire_lock, 65000)
  assert(locked, lock_err)
  lifecycle.release_lock()
  record("reclaimed")
  vim.cmd("qa!")
end

local data = input()
local action = mode
local locked, lock_err = await(lifecycle.acquire_lock)
assert(locked, lock_err)
lifecycle.set_test_hook(action, control .. ".marker", control .. ".resume")
local ok, err
if action == "pending_write" then
  ok, err = lifecycle.write_pending(data.pending)
elseif action == "pending_remove" then
  ok, err = lifecycle.remove_matching_pending_while_locked(data.pending.generation, "fence test pending removal")
elseif action == "state_publish" then
  ok, err = lifecycle.write_state(data.state, "fence test state publication")
elseif action == "state_remove" then
  ok, err = lifecycle.remove_matching_state_while_locked(data.state.generation, "fence test state removal")
elseif action == "signal" then
  ok, err = await(function(done)
    lifecycle.signal_process(data.process, data.boot_id, "sigterm", done)
  end, 65000)
else
  error("unknown fence action " .. action)
end
lifecycle.release_lock()
assert(ok, err)
if action == "signal" then
  record("completed")
  vim.cmd("qa!")
end

vim.fn.writefile({ "released" }, control .. ".released")
assert(vim.wait(10000, function()
  return vim.uv.fs_stat(control .. ".retry") ~= nil
end, 10), "stale retry timed out")
if action == "pending_write" then
  ok, err = lifecycle.write_pending(data.pending)
elseif action == "pending_remove" then
  ok, err = lifecycle.remove_matching_pending_while_locked(data.pending.generation, "stale pending removal")
elseif action == "state_publish" then
  ok, err = lifecycle.write_state(data.state, "stale state publication")
else
  ok, err = lifecycle.remove_matching_state_while_locked(data.state.generation, "stale state removal")
end
assert(not ok and err:find("fence", 1, true), err)
record("completed", "stale-refused")
vim.cmd("qa!")
