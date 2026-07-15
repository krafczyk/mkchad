local config = assert(arg[1], "pass the MkChad config path")
local server_config = assert(arg[2], "pass an isolated server config path")
local mode = assert(arg[3], "pass tls or direct mode")
local canary = assert(vim.env.MKCHAD_DISCLOSURE_CANARY, "missing generated disclosure canary")
local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

assert(vim.fn.mkdir(vim.fs.dirname(server_config), "p", 448) ~= 0 or vim.uv.fs_stat(vim.fs.dirname(server_config)))
local config_value = {
  username = "disclosure-user",
  password = canary,
  tls_proxy = mode == "tls",
}
local config_blob = vim.json.encode(config_value)
vim.fn.writefile({ config_blob }, server_config)
assert(vim.uv.fs_chmod(server_config, 384))
vim.g.mkchad_opencode_test_api = true
vim.g.mkchad_opencode_test_server_config = server_config
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()
assert(vim.fn.mkdir(paths.root, "p", 448) ~= 0 or vim.uv.fs_stat(paths.root))

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 40000, function()
    return done
  end, 20), "authentication operation timed out")
  return unpack(values)
end

local function assert_absent(label, value)
  value = value or ""
  assert(not value:find(canary, 1, true), label .. " exposed the generated password")
  assert(not value:find(config_blob, 1, true), label .. " exposed the protected config")
end

local fake = vim.fs.joinpath(paths.root, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import base64, os, socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('auth-fixture'); raise SystemExit(0)",
  "password = os.environ['OPENCODE_SERVER_PASSWORD']",
  "username = os.environ.get('OPENCODE_SERVER_USERNAME', 'opencode')",
  "expected = (b'authorization: basic ' + base64.b64encode((username + ':' + password).encode())).lower()",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen(64)",
  "def handle(client):",
  "  with client:",
  "    while True:",
  "      raw = b''",
  "      while b'\\r\\n\\r\\n' not in raw:",
  "        part = client.recv(4096)",
  "        if not part: return",
  "        raw += part",
  "      head = raw.split(b'\\r\\n\\r\\n', 1)[0].lower()",
  "      if expected not in head:",
  "        client.sendall(b'HTTP/1.1 401 Unauthorized\\r\\nContent-Length: 0\\r\\nConnection: keep-alive\\r\\n\\r\\n'); continue",
  "      body = b'{\\\"healthy\\\":true,\\\"version\\\":\\\"auth-fixture\\\"}'",
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=handle, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = paths.root .. ":" .. vim.env.PATH

package.loaded["snacks.terminal"] = {
  get = function(_, opts)
    if mode == "tls" then
      assert(opts.env and opts.env.NODE_EXTRA_CA_CERTS)
    else
      assert(not opts.env or not opts.env.NODE_EXTRA_CA_CERTS)
    end
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

local started, start_err = await(vim.g.opencode_opts.server.ensure)
assert(started, start_err)
local state = assert(lifecycle.read_state())
assert(state.transport == (mode == "tls" and "tls-proxy" or "loopback-http"))

local unauthenticated = { "curl", "--silent", "--output", "/dev/null", "--write-out", "%{http_code}" }
if mode == "tls" then
  vim.list_extend(unauthenticated, { "--cacert", state.ca_path })
end
table.insert(unauthenticated, state.url .. "/global/health")
local unauthenticated_code = vim.fn.system(unauthenticated)
assert(vim.v.shell_error == 0 and unauthenticated_code == "401", "unauthenticated public request was not rejected")

local protected_config = {
  "silent",
  'user = "disclosure-user:' .. canary .. '"',
  'output = "/dev/null"',
  'write-out = "%{http_code}"',
  'url = "' .. state.url .. '/global/health"',
}
if mode == "tls" then
  table.insert(protected_config, 2, 'cacert = "' .. state.ca_path .. '"')
end
local authenticated_code = vim.fn.system({ "curl", "--config", "-" }, table.concat(protected_config, "\n"))
assert(vim.v.shell_error == 0 and authenticated_code == "200", "authenticated public request failed")

if mode == "tls" then
  local internal_url = "http://127.0.0.1:" .. state.backend.port .. "/global/health"
  local internal_unauthenticated = vim.fn.system({
    "curl",
    "--silent",
    "--output",
    "/dev/null",
    "--write-out",
    "%{http_code}",
    internal_url,
  })
  assert(vim.v.shell_error == 0 and internal_unauthenticated == "401", "unauthenticated internal request was not rejected")
  local internal_authenticated = vim.fn.system({ "curl", "--config", "-" }, table.concat({
    "silent",
    'user = "disclosure-user:' .. canary .. '"',
    'output = "/dev/null"',
    'write-out = "%{http_code}"',
    'url = "' .. internal_url .. '"',
  }, "\n"))
  assert(vim.v.shell_error == 0 and internal_authenticated == "200", "authenticated internal request failed")
end

assert_absent("state", table.concat(vim.fn.readfile(paths.state), "\n"))
for _, process in ipairs(state.proxy and { state.backend, state.proxy } or { state.backend }) do
  assert_absent("process argv", table.concat(vim.fn.readfile("/proc/" .. process.pid .. "/cmdline", "b"), "\n"))
end
for _, log in ipairs({ paths.log, paths.proxy_log }) do
  if vim.uv.fs_stat(log) then
    assert_absent("managed log", table.concat(vim.fn.readfile(log, "b"), "\n"))
  end
end
assert_absent("notifications", table.concat(notifications, "\n"))

lifecycle.stop_shared_server()
assert(vim.wait(15000, function()
  return lifecycle.read_state() == nil
end, 20), "authenticated fixture cleanup timed out")
vim.uv.fs_unlink(server_config)
vim.cmd("qa!")
