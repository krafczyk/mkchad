local config = assert(arg[1], "pass the MkChad config path")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = assert(lifecycle.ensure_state_dir())

local function await(invoke)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(
    vim.wait(5000, function()
      return done
    end, 10),
    "broker response timed out"
  )
  return unpack(values)
end

local function frame(body)
  local size = #body
  return string.char(
    math.floor(size / 16777216) % 256,
    math.floor(size / 65536) % 256,
    math.floor(size / 256) % 256,
    size % 256
  ) .. body
end

local function escaped(value)
  return value:gsub("\\", "\\\\"):gsub('"', '\\"')
end

local self_pid = vim.fn.getpid()
local self_executable = assert(vim.uv.fs_readlink("/proc/" .. self_pid .. "/exe"))
local self_identity = assert(lifecycle.file_identity("/proc/" .. self_pid .. "/exe"))
local source_identity = assert(lifecycle.file_identity(paths.proxy_source))
local self_argv = vim.split(
  table.concat(vim.fn.readfile("/proc/" .. self_pid .. "/cmdline", "b"), "\n"),
  "\0",
  { plain = true, trimempty = true }
)
local proxy = {
  pid = self_pid,
  port = 4096,
  argv = self_argv,
  process_executable = self_executable,
  process_executable_dev = self_identity.dev,
  process_executable_ino = self_identity.ino,
  executable = self_executable,
  executable_dev = self_identity.dev,
  executable_ino = self_identity.ino,
  start_time = assert(lifecycle.proc_start_time(self_pid)),
  source = paths.proxy_source,
  source_dev = source_identity.dev,
  source_ino = source_identity.ino,
}

local function response(request, control, overrides)
  overrides = overrides or {}
  return vim.json
    .encode({
      protocol = overrides.protocol or 1,
      operation = overrides.operation or request.operation,
      generation = overrides.generation or request.generation,
      nonce = overrides.nonce or request.nonce,
      phase = overrides.phase or "control-ready",
      control = overrides.control or control,
      proxy = overrides.proxy or proxy,
      backend = overrides.backend,
    })
    :gsub(',"backend":null', "")
end

local function assert_rejected(name, make_reply)
  vim.uv.fs_unlink(paths.control)
  local listener = assert(vim.uv.new_pipe(false))
  assert(listener:bind(paths.control) == 0)
  assert(vim.uv.fs_chmod(paths.control, 384))
  local socket_stat = assert(vim.uv.fs_lstat(paths.control))
  local socket = { dev = tostring(socket_stat.dev), ino = tostring(socket_stat.ino) }
  assert(listener:listen(1, function(accept_err)
    assert(not accept_err, accept_err)
    local client = assert(vim.uv.new_pipe(false))
    listener:accept(client)
    local chunks = {}
    client:read_start(function(read_err, chunk)
      assert(not read_err, read_err)
      if chunk then
        table.insert(chunks, chunk)
        return
      end
      local request_frame = table.concat(chunks)
      local size = request_frame:byte(1) * 16777216
        + request_frame:byte(2) * 65536
        + request_frame:byte(3) * 256
        + request_frame:byte(4)
      local request = vim.json.decode(request_frame:sub(5, size + 4))
      local reply = make_reply(request, socket)
      client:write(reply, function()
        client:shutdown(function()
          client:close()
          listener:close()
        end)
      end)
    end)
  end))
  local received, err = await(function(done)
    lifecycle.broker_exchange(paths.control, "status", "expected-generation", paths.root_identity, socket, done)
  end)
  assert(not received and err, name .. " authorized a broker response")
  assert(
    not vim.uv.fs_stat(paths.launch) and not vim.uv.fs_stat(paths.pending) and not vim.uv.fs_stat(paths.state),
    name .. " authorized lifecycle state"
  )
  assert(not vim.uv.fs_stat(vim.fs.joinpath(paths.root, "opencode")), name .. " launched a backend")
end

assert_rejected("duplicate top-level field", function(request, control)
  return frame(response(request, control):gsub('"phase"', '"phase":"control-ready","phase"', 1))
end)
assert_rejected("unknown top-level field", function(request, control)
  return frame(response(request, control):sub(1, -2) .. ',"unknown":true}')
end)
assert_rejected("duplicate control field", function(request, control)
  local body = response(request, control):gsub(
    '"dev":"' .. escaped(control.dev) .. '"',
    '"dev":"' .. escaped(control.dev) .. '","dev":"' .. escaped(control.dev) .. '"',
    1
  )
  return frame(body)
end)
assert_rejected("unknown control field", function(request, control)
  local body = response(request, control):gsub(
    '"ino":"' .. escaped(control.ino) .. '"',
    '"ino":"' .. escaped(control.ino) .. '","unknown":true',
    1
  )
  return frame(body)
end)
assert_rejected("duplicate backend field", function(request, control)
  return frame(
    response(request, control, { phase = "running", backend = { pid = 1, port = 1 } }):gsub(
      '"pid":1',
      '"pid":1,"pid":1',
      1
    )
  )
end)
assert_rejected("unknown backend field", function(request, control)
  return frame(response(request, control, { phase = "running", backend = { pid = 1, unknown = true } }))
end)
assert_rejected("trailing bytes", function(request, control)
  return frame(response(request, control)) .. "x"
end)
assert_rejected("running without backend", function(request, control)
  return frame(response(request, control, { phase = "running" }))
end)
assert_rejected("control-ready with backend", function(request, control)
  return frame(response(request, control, { backend = { pid = 1 } }))
end)
assert_rejected("wrong generation", function(request, control)
  return frame(response(request, control, { generation = "wrong-generation" }))
end)
assert_rejected("wrong nonce", function(request, control)
  return frame(response(request, control, { nonce = "wrong-nonce" }))
end)
assert_rejected("wrong control inode", function(request, control)
  local wrong_inode = control.ino == "1" and "2" or "1"
  return frame(response(request, { path = paths.control, dev = control.dev, ino = wrong_inode }))
end)
assert_rejected("oversized response", function()
  return string.char(0, 1, 0, 1) .. string.rep("x", 65537)
end)
assert_rejected("partial response", function()
  return string.char(0, 0, 0, 8) .. "{}"
end)
assert_rejected("invalid JSON", function()
  return frame "{not-json}"
end)

vim.uv.fs_unlink(paths.control)
vim.cmd "qa!"
