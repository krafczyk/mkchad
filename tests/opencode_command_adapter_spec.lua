local config = assert(arg[1], "pass the MkChad config path")
local root = assert(vim.env.XDG_STATE_HOME, "use an isolated state path")
local fixture = vim.fs.joinpath(root, "command-fixture.py")
local log = vim.fs.joinpath(root, "command-actions.log")

assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import json, os, sys, time",
  "action = sys.argv[1]",
  "with open(os.environ['MKCHAD_COMMAND_LOG'], 'a') as output: output.write(action + '\\n')",
  "if action == 'status':",
  "  if os.environ.get('MKCHAD_STATUS_MODE') == 'healthy': print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'healthy', 'state': {'url': 'http://127.0.0.1:4096', 'transport': 'loopback-http', 'generation': 'external-generation', 'ca_cert': None, 'server_version': 'fixture-server'}}))",
  "  else: print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'inactive', 'state': None}))",
  "  raise SystemExit(0)",
  "if action == 'stop': print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'inactive', 'state': None})); raise SystemExit(0)",
  "mode = os.environ.get('MKCHAD_COMMAND_MODE', 'valid')",
  "if mode == 'malformed': print('not json')",
  "elif mode == 'trailing': print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'healthy', 'state': {'url': 'http://127.0.0.1:4096', 'transport': 'loopback-http', 'generation': 'external-generation', 'ca_cert': None}}) + ' trailing')",
  "elif mode == 'oversized': print('x' * (64 * 1024 + 1))",
  "elif mode == 'exit': print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'healthy', 'state': {'url': 'http://127.0.0.1:4096', 'transport': 'loopback-http', 'generation': 'external-generation', 'ca_cert': None}})); raise SystemExit(7)",
  "elif mode == 'badversion': print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'healthy', 'state': {'url': 'http://127.0.0.1:4096', 'transport': 'loopback-http', 'generation': 'external-generation', 'ca_cert': None, 'server_version': 7}}))",
  "elif mode == 'blocked': print(json.dumps({'schema': 1, 'ok': False, 'command': action, 'status': 'blocked', 'error': {'code': 'fixture_blocked', 'message': 'fixture refused startup'}})); raise SystemExit(1)",
  "elif mode == 'legacy': print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'healthy', 'state': {'url': 'http://127.0.0.1:4096', 'transport': 'loopback-http', 'generation': 'legacy-generation', 'ca_cert': None}}))",
  "else:",
  "  if mode == 'slow': time.sleep(0.3); generation = 'stale-generation'",
  "  elif mode == 'valid2': generation = 'new-generation'",
  "  else: generation = 'external-generation'",
  "  print(json.dumps({'schema': 1, 'ok': True, 'command': action, 'status': 'healthy', 'state': {'url': 'http://127.0.0.1:4096', 'transport': 'loopback-http', 'generation': generation, 'ca_cert': None, 'server_version': 'fixture-server'}}))",
}, fixture)
assert(vim.uv.fs_chmod(fixture, 493))

vim.g.mkchad_opencode_test_api = true
vim.g.mkchad_opencode_test_command_argv = { "python3", fixture }
vim.env.MKCHAD_COMMAND_LOG = log
dofile(config)
local api = vim.g.mkchad_opencode_test_api
assert(type(api.command_adapter_ensure) == "function", "missing command adapter test seam")
local fixture_argv = vim.g.mkchad_opencode_test_command_argv
local home = vim.env.HOME
local test_home = vim.fs.joinpath(root, "home")
local test_bin = vim.fs.joinpath(test_home, ".local", "bin")
local image_command = vim.fs.joinpath(test_bin, "mkchad-opencode-server-image")
assert(vim.fn.mkdir(test_bin, "p", 448) ~= 0 or vim.uv.fs_stat(test_bin))
vim.fn.writefile({ "#!/usr/bin/env bash" }, image_command)
assert(vim.uv.fs_chmod(image_command, 493))
vim.env.HOME = test_home
vim.g.mkchad_opencode_test_command_argv = nil
local production_argv = api.command_adapter_argv("status")
assert(production_argv[1] == image_command, "production adapter did not use the installed in-image command path")
assert(production_argv[2] == "status" and production_argv[3] == "--json", "production adapter argv changed")
assert(vim.uv.fs_unlink(image_command))
local fallback_argv = api.command_adapter_argv("status")
assert(fallback_argv[1] == vim.fs.joinpath(test_bin, "mkchad-opencode-server"), "production adapter did not preserve staggered-upgrade fallback")
vim.env.HOME = nil
local missing_home_argv, missing_home_err = api.command_adapter_argv("status")
vim.env.HOME = home
vim.g.mkchad_opencode_test_command_argv = fixture_argv
assert(missing_home_argv == nil and missing_home_err:find("HOME must be an absolute path", 1, true), "missing HOME did not fail closed")

local function await(invoke)
  local calls, result = 0, nil
  invoke(function(...)
    calls, result = calls + 1, { ... }
  end)
  assert(vim.wait(5000, function()
    return result ~= nil
  end, 10), "command callback timed out")
  vim.wait(100, function()
    return false
  end, 10)
  assert(calls == 1, "command callback ran more than once")
  return unpack(result, 1, 3)
end

local function expect_start_failure(mode)
  vim.env.MKCHAD_COMMAND_MODE = mode
  local ok, err = await(api.command_adapter_ensure)
  assert(ok == false, mode .. " command output was accepted")
  local url
  vim.g.opencode_opts.server.url(function(value)
    url = value
  end)
  assert(url == nil, mode .. " retained a stale endpoint")
  return err
end

expect_start_failure("malformed")
expect_start_failure("trailing")
expect_start_failure("oversized")
expect_start_failure("exit")
expect_start_failure("badversion")
assert(expect_start_failure("blocked") == "mkchad-opencode-server: fixture refused startup", "structured command failure was hidden")
vim.g.mkchad_opencode_test_command_argv = { vim.fs.joinpath(root, "missing-command") }
local spawn_ok, spawn_err = await(api.command_adapter_ensure)
vim.g.mkchad_opencode_test_command_argv = fixture_argv
assert(spawn_ok == false and spawn_err:find("unable to start missing-command", 1, true), "spawn failure was hidden")

vim.env.MKCHAD_COMMAND_MODE = "legacy"
local legacy_ok, legacy_err, legacy_state = await(api.command_adapter_ensure)
assert(legacy_ok and not legacy_err and legacy_state.generation == "legacy-generation" and legacy_state.server_version == nil)

vim.env.MKCHAD_COMMAND_MODE = "valid"
local ok, err, state = await(api.command_adapter_ensure)
assert(ok and not err and state.generation == "external-generation" and state.server_version == "fixture-server")
local url
vim.g.opencode_opts.server.url(function(value)
  url = value
end)
assert(url == "http://127.0.0.1:4096", "validated external generation was not cached")
assert(vim.g.opencode_opts.server.ca_cert() == nil, "direct command result exposed a CA")

vim.env.MKCHAD_COMMAND_MODE = "slow"
local first = nil
api.command_adapter_ensure(function(value)
  first = value
end)
vim.env.MKCHAD_COMMAND_MODE = "valid2"
local second, _, second_state = await(api.command_adapter_ensure)
assert(second and second_state.generation == "new-generation")
assert(vim.wait(5000, function()
  return first ~= nil
end, 10), "stale command did not complete")
assert(first == false, "stale command completion was accepted")
vim.g.opencode_opts.server.url(function(value)
  url = value
end)
assert(url == "http://127.0.0.1:4096", "stale completion replaced the current endpoint")

local status = await(api.command_adapter_status)
assert(status == "inactive", "status was not delegated to the command")
vim.env.MKCHAD_STATUS_MODE = "healthy"
local healthy_status, healthy_state = await(api.command_adapter_status)
assert(healthy_status == "healthy" and healthy_state.server_version == "fixture-server", "status omitted server version")
local info
local original_notify = vim.notify
vim.notify = function(message)
  info = message
end
api.show_info()
assert(vim.wait(5000, function()
  return info ~= nil
end, 10), "OpenCodeInfo callback timed out")
vim.notify = original_notify
vim.env.MKCHAD_STATUS_MODE = nil
assert(info:find("Server version: fixture-server", 1, true), "OpenCodeInfo omitted server version")
local attached, closed = 0, false
package.loaded["snacks.terminal"] = {
  get = function()
    attached = attached + 1
    local job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(60)" })
    return {
      job = job,
      valid = function()
        return true
      end,
      show = function() end,
      close = function()
        closed = true
        vim.fn.jobstop(job)
      end,
    }, true
  end,
}
vim.env.MKCHAD_COMMAND_MODE = "valid"
vim.cmd("OpenCodeStart")
assert(vim.wait(2000, function()
  return attached == 1
end, 10), "editor did not attach to the externally returned generation")
vim.cmd("OpenCodeStop")
assert(vim.wait(2000, function()
  return closed
end, 10), "editor stop did not close its local TUI after command success")
vim.g.opencode_opts.server.url(function(value)
  url = value
end)
assert(url == nil, "stop did not clear the endpoint cache")

local actions = table.concat(vim.fn.readfile(log), ",")
assert(actions:find("status", 1, true) and actions:find("stop", 1, true), "status or stop bypassed the command")
print("opencode command adapter tests passed")
