local config = assert(arg[1], "pass the MkChad config path")
local mode = arg[2] or "setup"
vim.g.mkchad_opencode_test_api = true
if vim.env.MKCHAD_OPENCODE_SERVER_CONFIG and vim.env.MKCHAD_OPENCODE_SERVER_CONFIG ~= "" then
  vim.g.mkchad_opencode_test_server_config = vim.env.MKCHAD_OPENCODE_SERVER_CONFIG
end
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local root = lifecycle.paths().root
local fake = vim.fs.joinpath(root, "opencode")

if mode == "setup" then
  assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))
  vim.fn.writefile({
    "#!/usr/bin/env python3",
    "import socket, sys, time, threading",
    "if len(sys.argv) > 1 and sys.argv[1] == '--version': print('fake'); raise SystemExit(0)",
    "time.sleep(0.6)",
    "sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
    "sock.bind(('127.0.0.1', int(sys.argv[-1]))); sock.listen()",
    "def handle(client):",
    "  with client:",
    "    while True:",
    "      raw = b''",
    "      while b'\\r\\n\\r\\n' not in raw:",
    "        part = client.recv(4096)",
    "        if not part: return",
    "        raw += part",
    "      body = b'{\\\"healthy\\\":true,\\\"version\\\":\\\"fake\\\"}'",
    "      client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: ' + str(len(body)).encode() + b'\\r\\nConnection: keep-alive\\r\\n\\r\\n' + body)",
    "while True:",
    "  client, _ = sock.accept(); threading.Thread(target=handle, args=(client,), daemon=True).start()",
  }, fake)
  assert(vim.uv.fs_chmod(fake, 493))
  vim.cmd("qa!")
end

if mode == "worker" then
  vim.env.PATH = root .. ":" .. vim.env.PATH
  package.loaded["snacks.terminal"] = {
    get = function(_, opts)
      if lifecycle.requested_transport() == "tls-proxy" then
        assert(opts.env and opts.env.NODE_EXTRA_CA_CERTS, "attached TLS TUI did not receive NODE_EXTRA_CA_CERTS")
      else
        assert(not opts.env or not opts.env.NODE_EXTRA_CA_CERTS, "attached direct TUI received NODE_EXTRA_CA_CERTS")
      end
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
  assert(vim.wait(40000, function()
    return done
  end, 10), "contender timed out")
  assert(ok, err)
  local state = lifecycle.read_state()
  if vim.env.MKCHAD_OPENCODE_EXPECT_FALLBACK == "1" then
    assert(state.port ~= 4096 and state.port_source == "fallback", "contenders must converge on a persisted high public fallback")
  end
  local record = { state.generation, tostring(state.backend.pid) }
  if state.proxy then
    table.insert(record, 2, tostring(state.proxy.pid))
  end
  vim.fn.writefile(record, vim.env.MKCHAD_OPENCODE_RESULT .. "." .. vim.fn.getpid())
  vim.cmd("qa!")
end

if mode == "cleanup" then
  local state = lifecycle.read_state()
  local pending = lifecycle.read_pending()
  if state or pending then
    local lock_done, locked, lock_err = false, nil, nil
    lifecycle.acquire_lock(function(ok, err)
      lock_done, locked, lock_err = true, ok, err
    end)
    assert(vim.wait(1000, function()
      return lock_done
    end, 10), "cleanup lock timed out")
    assert(locked, lock_err)
    if state then
      local done, cleaned = false, nil
      lifecycle.stop_pair(state, vim.uv.hrtime() + 8000 * 1000000, function(ok)
        cleaned, done = ok, true
      end)
      assert(vim.wait(10000, function()
        return done
      end, 10), "server cleanup timed out")
      assert(cleaned, "server cleanup failed")
      vim.uv.fs_unlink(lifecycle.paths().state)
    end
    if lifecycle.read_pending() then
      local done, cleaned = false, nil
      lifecycle.cleanup_pending(vim.uv.hrtime() + 8000 * 1000000, function(ok)
        cleaned, done = ok, true
      end)
      assert(vim.wait(10000, function()
        return done
      end, 10), "pending cleanup timed out")
      assert(cleaned, "pending cleanup failed")
    end
    lifecycle.release_lock()
  end
  vim.cmd("qa!")
end
