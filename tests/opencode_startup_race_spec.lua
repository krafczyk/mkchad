local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api

local function await(invoke)
  local done, values = false
  invoke(function(...)
    values = { ... }
    done = true
  end)
  assert(vim.wait(40000, function()
    return done
  end, 10), "timed out")
  return unpack(values)
end

-- A fake backend launches a separate listener on its assigned internal port.
-- Backend listener proof must fail before the TLS proxy or any credentialed
-- public request is launched.
local acquired = await(lifecycle.acquire_lock)
assert(acquired, "could not acquire test lock")
local fake = vim.fs.joinpath(lifecycle.paths().root, "opencode")
local pid_record = vim.fs.joinpath(lifecycle.paths().root, "spawned.pid")
local responder_pid_record = vim.fs.joinpath(lifecycle.paths().root, "responder.pid")
local request_record = vim.fs.joinpath(lifecycle.paths().root, "health-requested")
vim.fn.writefile({
  "#!/bin/sh",
  'if [ "$1" = "--version" ]; then echo fake; exit 0; fi',
  "echo $$ > \"" .. pid_record .. "\"",
  "python3 -c 'import pathlib,socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"127.0.0.1\",int(sys.argv[1]))); s.listen(); c,a=s.accept(); pathlib.Path(sys.argv[2]).write_bytes(c.recv(4096)); c.sendall(b\"HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\n\\r\\n{\\\"healthy\\\":true}\"); c.close()' \"$5\" \""
    .. request_record
    .. "\" &",
  "echo $! > \"" .. responder_pid_record .. "\"",
  "exec python3 -c 'import time; time.sleep(30)' \"$@\"",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = lifecycle.paths().root .. ":" .. vim.env.PATH
vim.env.OPENCODE_SERVER_PASSWORD = "must-not-reach-startup-race-listener"
local state, err = await(function(done)
  lifecycle.spawn_pair(nil, vim.uv.hrtime() + 30000 * 1000000, done)
end)
assert(not state, "separate internal listener was incorrectly adopted")
assert(err:find("backend listener failed", 1, true), err)
assert(not lifecycle.read_state(), "failed generation state was retained after cleanup")
assert(not vim.uv.fs_stat(request_record), "startup sent any HTTP bytes to an unverified internal listener")
local spawned_pid = tonumber(vim.fn.readfile(pid_record)[1])
assert(spawned_pid and vim.wait(1000, function()
  if not vim.uv.fs_stat("/proc/" .. spawned_pid) then
    return true
  end
  local stat = vim.fn.readfile("/proc/" .. spawned_pid .. "/stat")[1]
  return stat and stat:match("%)%s+(%a)") == "Z"
end, 10), "failed generation remained as a live orphan")
local responder_pid = tonumber(vim.fn.readfile(responder_pid_record)[1])
if responder_pid and vim.uv.fs_stat("/proc/" .. responder_pid) then
  vim.uv.kill(responder_pid, "sigkill")
end
vim.env.OPENCODE_SERVER_PASSWORD = nil
lifecycle.release_lock()
vim.cmd("qa!")
