local config = assert(arg[1], "pass the MkChad config path")
local mode = arg[2] or "setup"
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local root = lifecycle.paths().root
local fake = vim.fs.joinpath(root, "opencode")

if mode == "setup" then
  assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
  vim.fn.writefile({
    "#!/usr/bin/env python3",
    "import socket, sys, time",
    "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('fake'); raise SystemExit(0)",
    "time.sleep(0.6)",
    "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
    "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen()",
    "while True:",
    "  client, _ = sock.accept(); client.recv(4096); client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\n\\r\\n{\\\"healthy\\\":true}'); client.close()",
  }, fake)
  assert(vim.uv.fs_chmod(fake, 493))
  vim.cmd("qa!")
end

if mode == "worker" then
  vim.env.PATH = root .. ":" .. vim.env.PATH
  package.loaded["snacks.terminal"] = {
    get = function()
      local job = vim.fn.jobstart({ "python3", "-c", "import time; time.sleep(5)" })
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
  local done, ok, err = false, nil, nil
  vim.g.opencode_opts.server.ensure(function(result, message)
    done, ok, err = true, result, message
  end)
  assert(vim.wait(6000, function()
    return done
  end, 10), "contender timed out")
  assert(ok, err)
  local state = lifecycle.read_state()
  if vim.env.MKCHAD_OPENCODE_EXPECT_FALLBACK == "1" then
    assert(state.port ~= 4096 and state.port_source == "fallback", "contenders must converge on a persisted high fallback")
  end
  vim.fn.writefile({ state.generation, tostring(state.pid) }, vim.env.MKCHAD_OPENCODE_RESULT .. "." .. vim.fn.getpid())
  vim.cmd("qa!")
end

if mode == "cleanup" then
  local state = lifecycle.read_state()
  if state then
    local done, cleaned = false, nil
    lifecycle.terminate_generation(state, vim.uv.hrtime() + 3000 * 1000000, function(ok)
      cleaned, done = ok, true
    end)
    assert(vim.wait(4000, function()
      return done
    end, 10), "server cleanup timed out")
    assert(cleaned, "server cleanup failed")
    vim.uv.fs_unlink(lifecycle.paths().state)
  end
  vim.cmd("qa!")
end
