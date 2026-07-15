local config = assert(arg[1], "pass the baseline MkChad config path")
local mode = assert(arg[2], "pass complete or pending mode")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
package.loaded["opencode.server"] = {}

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 5000, function()
    return done
  end, 20), "baseline operation timed out")
  return unpack(values)
end

if mode == "rollback-start" then
  local result_path = assert(arg[3], "pass a rollback result path")
  package.loaded["snacks.terminal"] = {
    get = function(_, opts)
      assert(opts.env and opts.env.NODE_EXTRA_CA_CERTS)
      local job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(60)" })
      return {
        job = job,
        valid = function()
          return true
        end,
        close = function(self)
          vim.fn.jobstop(self.job)
        end,
      }, true
    end,
  }
  local started, start_err = await(vim.g.opencode_opts.server.ensure, 40000)
  assert(started, start_err)
  local state = assert(lifecycle.read_state())
  assert(state.schema == 2, "baseline rollback did not publish schema-2 state")
  vim.fn.writefile({ state.generation, tostring(state.proxy.pid), tostring(state.backend.pid) }, result_path)
  lifecycle.stop_shared_server()
  assert(vim.wait(40000, function()
    return lifecycle.read_state() == nil
  end, 20), "baseline rollback stop timed out")
  vim.cmd("qa!")
end

local resolved_url
vim.g.opencode_opts.server.url(function(url)
  resolved_url = url or false
end)
assert(resolved_url == false, "baseline exposed a schema-3 URL")
assert(vim.g.opencode_opts.server.ca_cert() == nil, "baseline exposed a schema-3 CA")

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end
lifecycle.show_info()
assert(vim.wait(5000, function()
  return #notifications > 0
end, 20), "baseline info timed out")

local reload_ok = await(lifecycle.reload_current_directory)
assert(not reload_ok, "baseline reload accepted schema-3 metadata")
local ensure_ok = await(vim.g.opencode_opts.server.ensure, 5000)
assert(not ensure_ok, "baseline ensure accepted schema-3 metadata")

local before_stop = #notifications
lifecycle.stop_shared_server()
assert(vim.wait(5000, function()
  return #notifications > before_stop
end, 20), "baseline stop timed out")
vim.notify = original_notify

if mode == "complete" then
  local state, status = lifecycle.read_state()
  assert(state == nil and status == "unsupported schema", "baseline did not classify schema-3 state as unsupported")
else
  assert(lifecycle.read_state() == nil, "pending-only baseline unexpectedly found complete state")
  local pending, status = lifecycle.read_pending()
  assert(pending == nil and status == "malformed", "baseline did not reject schema-3 pending metadata")
end

vim.cmd("qa!")
