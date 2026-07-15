local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
local server_config = arg[2]
if server_config then
  assert(vim.fn.mkdir(vim.fs.dirname(server_config), "p", 448) ~= 0 or vim.uv.fs_stat(vim.fs.dirname(server_config)))
  vim.fn.writefile({ vim.json.encode({ tls_proxy = false }) }, server_config)
  assert(vim.uv.fs_chmod(server_config, 384))
  vim.g.mkchad_opencode_test_server_config = server_config
end
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local root = lifecycle.paths().root
assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
local directory = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 40000, function()
    return done
  end, 20), "timed out")
  return unpack(values)
end

local inactive_ok, inactive_message = await(lifecycle.reload_current_directory, 1000)
assert(not inactive_ok and inactive_message:find("did not start a server", 1, true), inactive_message)
assert(not lifecycle.read_state(), "inactive reload created lifecycle state")

local requests = vim.fs.joinpath(root, "reload_requests.log")
local fake = vim.fs.joinpath(root, "opencode")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import json, os, socket, sys, threading",
  "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('fake'); raise SystemExit(0)",
  "directory = " .. vim.json.encode(directory),
  "log = " .. vim.json.encode(requests),
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen(64)",
  "def handle(client):",
  "  with client:",
  "    while True:",
  "      raw = b''",
  "      while b'\\r\\n\\r\\n' not in raw:",
  "        part = client.recv(8192)",
  "        if not part: return",
  "        raw += part",
  "      lines = raw.decode('latin1').split('\\r\\n'); target = lines[0].split()[1]",
  "      routed = next((line for line in lines if line.lower().startswith('x-opencode-directory:')), '')",
  "      with open(log, 'a') as out: out.write(lines[0] + '|' + routed + '\\n')",
  "      if target == '/global/health': body = {'healthy': True, 'version': 'fake'}",
  "      elif target == '/session/status' and os.path.exists(log + '.busy'): body = {'status': 'busy'}",
  "      elif target == '/path': body = {'directory': directory}",
  "      else: body = [] if target in ('/permission', '/question') else {}",
  "      encoded = json.dumps(body).encode()",
  "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(encoded)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + encoded)",
  "while True:",
  "  client, _ = sock.accept(); threading.Thread(target=handle, args=(client,), daemon=True).start()",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = root .. ":" .. vim.env.PATH

local tui_creations, tui_jobs = 0, {}
package.loaded["snacks.terminal"] = {
  get = function(_, opts)
    if lifecycle.requested_transport() == "tls-proxy" then
      assert(opts.env.NODE_EXTRA_CA_CERTS)
    else
      assert(not opts.env or not opts.env.NODE_EXTRA_CA_CERTS)
    end
    tui_creations = tui_creations + 1
    local job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(60)" })
    table.insert(tui_jobs, job)
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
local ensured, ensure_err = await(vim.g.opencode_opts.server.ensure)
assert(ensured, ensure_err)
local state = assert(lifecycle.read_state())
local disconnected = false
package.loaded["opencode.server"] = { connected = { disconnect = function()
  disconnected = true
end } }
package.loaded["opencode.server.discovery"] = {
  get = function()
    return {
      next = function(_, success)
        success()
        return { catch = function() end }
      end,
    }
  end,
}

local ok, message = await(lifecycle.reload_current_directory, 10000)
assert(ok, message)
assert(disconnected, "reload did not clear stale plugin connection")
assert(tui_creations == 2, "reload did not recreate the local TUI")
local final = assert(lifecycle.read_state())
assert(final.backend.pid == state.backend.pid)
assert((not final.proxy and not state.proxy) or final.proxy.pid == state.proxy.pid)
assert(final.generation == state.generation and final.url == state.url and final.port == state.port)
assert(final.certificate_identity == state.certificate_identity)
local seen = table.concat(vim.fn.readfile(requests), "\n")
assert(seen:find("GET /session/status HTTP/1.1|x-opencode-directory: " .. directory, 1, true))
assert(seen:find("POST /instance/dispose HTTP/1.1|x-opencode-directory: " .. directory, 1, true))
assert(seen:find("GET /path HTTP/1.1|x-opencode-directory: " .. directory, 1, true))
local dispose_count = select(2, seen:gsub("POST /instance/dispose", ""))

package.loaded["opencode.server.discovery"].get = function()
  local pending = {}
  function pending:next()
    return self
  end
  function pending:catch(reject)
    vim.schedule(function()
      reject("initial SSE connection closed before server.connected")
    end)
    return self
  end
  return pending
end
local reconnect_ok, reconnect_message = await(lifecycle.reload_current_directory, 10000)
assert(not reconnect_ok and reconnect_message:find("plugin reconnection", 1, true), reconnect_message)
assert(reconnect_message:find("closed before server.connected", 1, true), reconnect_message)
dispose_count = select(2, table.concat(vim.fn.readfile(requests), "\n"):gsub("POST /instance/dispose", ""))

vim.fn.writefile({ "busy" }, requests .. ".busy")
local busy_ok, busy_message = await(lifecycle.reload_current_directory, 5000)
assert(not busy_ok and busy_message:find("work is active", 1, true), busy_message)
local final_requests = table.concat(vim.fn.readfile(requests), "\n")
assert(dispose_count == select(2, final_requests:gsub("POST /instance/dispose", "")), "busy reload disposed the instance")

local locked, lock_err = await(lifecycle.acquire_lock, 3000)
assert(locked, lock_err)
local stopped, stop_err = await(function(done)
  lifecycle.stop_pair(final, vim.uv.hrtime() + 8000 * 1000000, done)
end, 10000)
assert(stopped, stop_err)
vim.uv.fs_unlink(lifecycle.paths().state)
lifecycle.release_lock()
for _, job in ipairs(tui_jobs) do
  if vim.fn.jobwait({ job }, 0)[1] == -1 then
    vim.fn.jobstop(job)
  end
end
if server_config then
  vim.uv.fs_unlink(server_config)
end
vim.cmd("qa!")
