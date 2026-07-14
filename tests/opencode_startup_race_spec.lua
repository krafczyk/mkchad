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
  assert(vim.wait(5000, function()
    return done
  end, 10), "timed out")
  return unpack(values)
end

-- The shell harness puts a fake, long-lived `opencode serve` on PATH and a
-- separate health responder on its requested port. Readiness must not adopt
-- that responder: the spawned PID does not own the listening socket.
local acquired = await(lifecycle.acquire_lock)
assert(acquired, "could not acquire test lock")
local fake = vim.fs.joinpath(lifecycle.paths().root, "opencode")
vim.fn.writefile({
  "#!/bin/sh",
  'if [ "$1" = "--version" ]; then echo fake; exit 0; fi',
  "python3 -c 'import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"127.0.0.1\",int(sys.argv[1]))); s.listen(); c,a=s.accept(); c.recv(4096); c.sendall(b\"HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\n\\r\\n{\\\"healthy\\\":true}\"); c.close()' \"$5\" &",
  "exec python3 -c 'import time; time.sleep(30)' \"$@\"",
}, fake)
assert(vim.uv.fs_chmod(fake, 493))
vim.env.PATH = lifecycle.paths().root .. ":" .. vim.env.PATH
local state, err = await(function(done)
  lifecycle.spawn_server(nil, vim.uv.hrtime() + 2500 * 1000000, done)
end)
assert(not state, "unknown health responder was incorrectly adopted")
assert(err:find("unexpected endpoint process", 1, true), err)
assert(not lifecycle.read_state(), "failed generation state was retained after cleanup")
lifecycle.release_lock()
vim.cmd("qa!")
