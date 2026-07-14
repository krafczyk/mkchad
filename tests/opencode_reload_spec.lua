local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local root = lifecycle.paths().root
assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
local directory = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
local inactive_done, inactive_ok, inactive_message = false, nil, nil
lifecycle.reload_current_directory(function(ok, message)
  inactive_done, inactive_ok, inactive_message = true, ok, message
end)
assert(vim.wait(1000, function() return inactive_done end, 10), "inactive reload did not finish")
assert(not inactive_ok and inactive_message:find("did not start a server", 1, true), inactive_message)
assert(not lifecycle.read_state(), "inactive reload created lifecycle state")

local port = 49889
local responder = vim.fs.joinpath(root, "reload_responder.py")
local requests = vim.fs.joinpath(root, "reload_requests.log")
vim.fn.writefile({
  "import json, os, socket, sys",
  "port, directory, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]",
  "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "sock.bind(('127.0.0.1', port)); sock.listen()",
  "while True:",
  "  client, _ = sock.accept(); raw = client.recv(8192).decode(); lines = raw.split('\\r\\n')",
  "  with open(log, 'a') as out: out.write(lines[0] + '|' + next((x for x in lines if x.lower().startswith('x-opencode-directory:')), '') + '\\n')",
  "  target = lines[0].split()[1]",
  "  if target == '/global/health': body = {'healthy': True, 'version': 'fake'}",
  "  elif target == '/session/status' and os.path.exists(log + '.busy'): body = {'status': 'busy'}",
  "  elif target == '/path': body = {'directory': directory}",
  "  else: body = [] if target in ('/permission', '/question') else {}",
  "  encoded = json.dumps(body).encode(); client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: ' + str(len(encoded)).encode() + b'\\r\\n\\r\\n' + encoded); client.close()",
}, responder)
local job = vim.fn.jobstart({ "python3", responder, tostring(port), directory, requests, "serve", "--hostname", "127.0.0.1", "--port", tostring(port) })
assert(job > 0, "could not start reload responder")
local pid = vim.fn.jobpid(job)
assert(vim.wait(1000, function()
  return lifecycle.process_listens_on_port(pid, port)
end, 10), "reload responder did not listen")
local cmdline_fd = assert(vim.uv.fs_open("/proc/" .. pid .. "/cmdline", "r", 0))
local cmdline_size = vim.uv.fs_fstat(cmdline_fd).size
local cmdline = assert(vim.uv.fs_read(cmdline_fd, cmdline_size == 0 and 8192 or cmdline_size, 0))
vim.uv.fs_close(cmdline_fd)
local state = {
  schema = 1,
  hostname = vim.uv.os_gethostname():gsub("[^%w_.-]", "_"),
  pid = pid,
  generation = "reload-test",
  host = "127.0.0.1",
  port = port,
  url = "http://127.0.0.1:" .. port,
  process_executable = vim.uv.fs_readlink("/proc/" .. pid .. "/exe"),
  argv = vim.split(cmdline, "\0", { plain = true, trimempty = true }),
}
assert(lifecycle.process_is_owned(state))
assert(lifecycle.write_state(state))

local disconnected, tui_creations = false, 0
package.loaded["opencode.server"] = { connected = { disconnect = function() disconnected = true end } }
package.loaded["snacks.terminal"] = {
  get = function()
    tui_creations = tui_creations + 1
    local tui_job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(10)" })
    return { job = tui_job, valid = function() return true end, close = function(self) vim.fn.jobstop(self.job) end }, true
  end,
}
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
local done, ok, message = false, nil, nil
lifecycle.reload_current_directory(function(result, detail)
  done, ok, message = true, result, detail
end)
assert(vim.wait(5000, function() return done end, 10), "reload did not finish")
assert(ok, message)
assert(disconnected, "reload did not clear stale plugin connection")
assert(tui_creations == 1, "reload did not recreate the local TUI")
local final = lifecycle.read_state()
assert(final.pid == state.pid and final.generation == state.generation and final.url == state.url and final.port == state.port, "reload changed shared state")
local seen = table.concat(vim.fn.readfile(requests), "\n")
assert(seen:find("GET /session/status HTTP/1.1|x%-opencode%-directory: " .. directory, 1), "status preflight was not directory routed")
assert(seen:find("POST /instance/dispose HTTP/1.1|x%-opencode%-directory: " .. directory, 1), "dispose was not directory routed")
assert(seen:find("GET /path HTTP/1.1|x%-opencode%-directory: " .. directory, 1), "recreation was not directory routed")
local dispose_count = select(2, seen:gsub("POST /instance/dispose", ""))
vim.fn.writefile({ "busy" }, requests .. ".busy")
local busy_done, busy_ok, busy_message = false, nil, nil
lifecycle.reload_current_directory(function(result, detail)
  busy_done, busy_ok, busy_message = true, result, detail
end)
assert(vim.wait(3000, function() return busy_done end, 10), "busy reload did not finish")
assert(not busy_ok and busy_message:find("work is active", 1, true), busy_message)
local final_requests = table.concat(vim.fn.readfile(requests), "\n")
assert(dispose_count == select(2, final_requests:gsub("POST /instance/dispose", "")), "busy reload disposed the instance")
vim.fn.jobstop(job)
vim.cmd("qa!")
