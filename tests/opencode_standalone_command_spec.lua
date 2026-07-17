-- Run with isolated XDG paths.  This is intentionally direct mode so the
-- command contract can be exercised without Java or a container runtime.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
local entrypoint = vim.fs.joinpath(root, "lua", "mkchad", "opencode", "command.lua")
local state_home = assert(vim.env.XDG_STATE_HOME, "set XDG_STATE_HOME to an isolated test path")
local config_home = assert(vim.env.XDG_CONFIG_HOME, "set XDG_CONFIG_HOME to an isolated test path")
local runtime_home = assert(vim.env.XDG_RUNTIME_DIR, "set XDG_RUNTIME_DIR to an isolated test path")
local nvim = assert(vim.fn.exepath("nvim") ~= "" and vim.fn.exepath("nvim"))
local fake_bin = vim.fs.joinpath(state_home, "fake-bin")
local config_dir = vim.fs.joinpath(config_home, "mkchad")
local server_config = vim.fs.joinpath(config_dir, "opencode-server.json")

assert(vim.fn.mkdir(fake_bin, "p", 448) ~= 0 or vim.uv.fs_stat(fake_bin))
assert(vim.fn.mkdir(config_dir, "p", 448) ~= 0 or vim.uv.fs_stat(config_dir))
assert(vim.fn.mkdir(runtime_home, "p", 448) ~= 0 or vim.uv.fs_stat(runtime_home))

local fake = vim.fs.joinpath(fake_bin, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('standalone-test'); raise SystemExit(0)",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen(32)",
  "def serve(client):",
  "  with client:",
  "    while True:",
  "      request = b''",
  "      while b'\\r\\n\\r\\n' not in request:",
  "        part = client.recv(4096)",
  "        if not part: return",
  "        request += part",
  "      body = b'{\\\"healthy\\\":true,\\\"version\\\":\\\"standalone-test\\\"}'",
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=serve, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.fn.writefile({ vim.json.encode({ tls_proxy = false }) }, server_config)
assert(vim.uv.fs_chmod(server_config, 384))

local environment = vim.fn.environ()
environment.HOME = vim.env.HOME
environment.XDG_CONFIG_HOME = config_home
environment.XDG_STATE_HOME = state_home
environment.XDG_RUNTIME_DIR = runtime_home
environment.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or vim.fs.joinpath(state_home, "data")
environment.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or vim.fs.joinpath(state_home, "cache")
environment.PATH = fake_bin .. ":" .. environment.PATH

local function invoke(...)
  local done, result = false, nil
  vim.system({ nvim, "--headless", "-u", "NONE", "-l", entrypoint, "--", ... }, { env = environment }, function(value)
    result, done = value, true
  end)
  assert(vim.wait(40000, function()
    return done
  end, 20), "standalone command timed out")
  return result
end

local inactive = invoke("status", "--json")
assert(inactive.code == 0 and inactive.stdout:match("^%b{}\n$"), inactive.stderr)
local inactive_result = vim.json.decode(inactive.stdout)
assert(inactive_result.ok and inactive_result.status == "inactive" and inactive_result.state == vim.NIL)
assert(not vim.uv.fs_stat(vim.fs.joinpath(state_home, "mkchad", "opencode")), "inactive status created lifecycle state")
local inactive_human = invoke("status")
assert(inactive_human.code == 0, inactive_human.stderr)
assert(inactive_human.stdout == table.concat({
  "Command status: inactive",
  "URL: inactive",
  "Transport: inactive",
  "Generation: inactive",
  "Server version: unknown",
  "",
}, "\n"), "inactive human status changed")

local started = invoke("start", "--json")
assert(started.code == 0 and started.stdout:match("^%b{}\n$"), started.stderr)
local started_result = vim.json.decode(started.stdout)
assert(started_result.ok and started_result.status == "healthy")
assert(started_result.state.transport == "loopback-http" and started_result.state.ca_cert == vim.NIL)
assert(started_result.state.server_version == "standalone-test")
assert(started_result.state.url:match("^http://127%.0%.0%.1:%d+$"))
local healthy_human = invoke("status")
assert(healthy_human.code == 0, healthy_human.stderr)
assert(healthy_human.stdout == table.concat({
  "Command status: healthy",
  "URL: " .. started_result.state.url,
  "Transport: loopback-http",
  "Generation: " .. started_result.state.generation,
  "Server version: standalone-test",
  "",
}, "\n"), "healthy human status did not report shared server details")

local reused = invoke("start", "--json")
assert(reused.code == 0, reused.stderr)
assert(vim.json.decode(reused.stdout).state.generation == started_result.state.generation, "start did not reuse the generation")

local stopped = invoke("stop", "--json")
assert(stopped.code == 0 and vim.json.decode(stopped.stdout).status == "inactive", stopped.stderr)
local invalid = invoke("start", "--json", "unexpected")
assert(invalid.code == 2 and invalid.stdout == "", "usage failure emitted machine output")

print("opencode standalone command tests passed")
